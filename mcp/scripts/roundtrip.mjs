// Round-trip stage (docs/spec/07): drive all 19 MCP tools ONCE each against the
// REAL daemon (plugsightd) booted on a seeded temp database, and assert every
// call round-trips to a well-formed result or a well-formed daemon error with a
// stable `kind` — never an unmapped/opaque crash. This is the N9 gate that N9
// itself had to defer ("pending N8"); N8 shipped the real daemon, so it is live.
//
// It is NOT part of the default `npm test` (that is the mock-daemon suite). Run
// it with `npm --prefix mcp run test:roundtrip`.
//
// What it does, end to end:
//   1. `swift build` from the repo root so `.build/debug/plugsightd` exists.
//   2. Boot the daemon once against a fresh temp state dir + temp DB so GRDB
//      migrates the schema, then stop it and seed ONE device via the `sqlite3`
//      CLI (the schema is a frozen contract, docs/spec/06). Booting twice is the
//      clean way to seed: the first boot owns the migration, the seed insert runs
//      while the DB is released, the second boot serves the seeded state.
//   3. Boot the daemon again on the same seed DB + state dir, point the SAME MCP
//      code path (PlugsightClient + the TOOLS table) at that state dir via the
//      injectable baseDir, run auth.hello, then invoke each of the 19 tools once.
//   4. SIGTERM the daemon and assert a clean (exit 0) shutdown.
// Exit non-zero on ANY tool that returned an unmapped error / unexpected outcome,
// on a daemon spawn/shutdown failure, or on the build failing. Exit 0 on success.

import { spawn, spawnSync } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { PlugsightClient } from "../src/client.ts";
import { TOOLS, executeTool } from "../src/tools.ts";

// MARK: - Paths

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "..", "..");
const DAEMON_BIN = path.join(REPO_ROOT, ".build", "debug", "plugsightd");
const SOCKET_FILENAME = "plugsightd.sock";
const TOKEN_FILENAME = "api-token";

// The stable error kinds the daemon (and the adapter) are allowed to speak
// (docs/spec/02 + mcp/src/errors.ts). Anything outside this set is "unmapped".
const STABLE_KINDS = new Set([
  "unauthorized",
  "not_found",
  "scanner_unavailable",
  "permission_missing",
  "es_inactive",
  "invalid_params",
  "conflict",
  "daemon_unreachable",
  "unsupported_api_version",
]);

const SCORE_CAVEAT =
  "Behavioral scoring is probabilistic and a patient attacker can evade it.";

const SEED_DEVICE_ID = "dev_seed0001";
const MISSING = "does_not_exist_0000";

// MARK: - Small helpers

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function log(line) {
  process.stdout.write(line + "\n");
}

/** Wait until both the socket and token files exist under `stateDir`. */
async function waitForDaemonFiles(stateDir, timeoutMs = 20_000) {
  const sock = path.join(stateDir, SOCKET_FILENAME);
  const token = path.join(stateDir, TOKEN_FILENAME);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(sock) && fs.existsSync(token)) {
      // Give the listener a beat to actually accept connections.
      await sleep(150);
      return;
    }
    await sleep(100);
  }
  throw new Error(
    `Daemon never wrote its socket + token under ${stateDir} within ${timeoutMs}ms.`,
  );
}

/**
 * Spawn plugsightd against a seed DB + state dir. Returns a handle with the
 * child and a `stop()` that SIGTERMs it and resolves with the exit code.
 */
function spawnDaemon(dbPath, stateDir) {
  const child = spawn(DAEMON_BIN, [], {
    cwd: REPO_ROOT,
    env: {
      ...process.env,
      PLUGSIGHT_SEED_DB: dbPath,
      PLUGSIGHT_STATE_DIR: stateDir,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let out = "";
  child.stdout.on("data", (c) => (out += c.toString()));
  child.stderr.on("data", (c) => (out += c.toString()));

  const exited = new Promise((resolve) => {
    child.on("exit", (code, signal) => resolve({ code, signal }));
  });

  let spawnError = null;
  child.on("error", (e) => (spawnError = e));

  return {
    child,
    get output() {
      return out;
    },
    get spawnError() {
      return spawnError;
    },
    exited,
    /** SIGTERM the daemon and resolve with { code, signal }. */
    async stop() {
      if (child.exitCode !== null || child.signalCode !== null) {
        return exited;
      }
      child.kill("SIGTERM");
      const raced = await Promise.race([
        exited,
        sleep(8_000).then(() => "timeout"),
      ]);
      if (raced === "timeout") {
        child.kill("SIGKILL");
        return { code: null, signal: "SIGKILL", killedHard: true };
      }
      return raced;
    },
  };
}

/** Boot the daemon, wait for readiness, run `fn`, then always stop it. */
async function withDaemon(dbPath, stateDir, fn) {
  const daemon = spawnDaemon(dbPath, stateDir);
  try {
    // If the binary can't spawn, surface it before the readiness timeout.
    const ready = Promise.race([
      waitForDaemonFiles(stateDir),
      daemon.exited.then((e) => {
        throw new Error(
          `Daemon exited before becoming ready (code=${e.code}, signal=${e.signal}).\n${daemon.output}`,
        );
      }),
    ]);
    await ready;
    if (daemon.spawnError) throw daemon.spawnError;
    return await fn(daemon);
  } finally {
    await daemon.stop();
  }
}

/** Insert one device (+ one interface) into the migrated seed DB via sqlite3. */
function seedDevice(dbPath) {
  const now = "2026-08-25T09:00:00.000Z";
  const sql = [
    `INSERT INTO devices (id, identity_key, identity_basis, vid, pid, serial, display_name, first_seen_at, last_seen_at, present, trust_tier) ` +
      `VALUES ('${SEED_DEVICE_ID}','seedkey-0001','serial',1133,49291,'SN-ROUNDTRIP','Seeded Round-trip Keyboard','${now}','${now}',1,'none');`,
    `INSERT INTO device_interfaces (device_id, seq, usb_class, usb_subclass, usb_protocol, role) ` +
      `VALUES ('${SEED_DEVICE_ID}',0,3,1,1,'keyboard');`,
  ].join("\n");
  const res = spawnSync("sqlite3", [dbPath], { input: sql, encoding: "utf8" });
  if (res.status !== 0) {
    throw new Error(
      `Seeding the device via sqlite3 failed (status ${res.status}): ${res.stderr || res.stdout}`,
    );
  }
}

// MARK: - Per-tool expectations
//
// One canned call per tool. `accept` is the set of acceptable outcomes:
//   { ok: true }                    -> a well-formed success is required
//   { kinds: [...] }                -> a well-formed error with one of these kinds
// A tool may accept both (e.g. scan_storage: ok OR scanner_unavailable). Missing
// ids deliberately exercise the not_found mapping without needing rich seed data.

const EXPECTATIONS = {
  // Read tools
  get_status: { args: {}, accept: { ok: true } },
  list_devices: { args: {}, accept: { ok: true } },
  get_device: { args: { deviceId: SEED_DEVICE_ID }, accept: { ok: true } },
  get_timeline: { args: {}, accept: { ok: true } },
  explain_event: { args: { eventId: MISSING }, accept: { kinds: ["not_found"] } },
  tail_events: { args: { waitSeconds: 0 }, accept: { ok: true } },
  score_device: {
    args: { deviceId: SEED_DEVICE_ID },
    accept: { ok: true },
    // Charter item: a score result for an existing device carries the caveat.
    check: (r) => {
      const caveat = r.structuredContent?.caveat;
      if (caveat !== SCORE_CAVEAT) {
        return `score_device result is missing the probabilistic-scoring caveat (got ${JSON.stringify(caveat)}).`;
      }
      return null;
    },
  },
  list_alerts: { args: {}, accept: { ok: true } },
  get_scan: { args: { scanId: MISSING }, accept: { kinds: ["not_found"] } },
  get_policy: { args: {}, accept: { ok: true } },

  // Write tools
  acknowledge_alert: { args: { alertId: MISSING }, accept: { kinds: ["not_found"] } },
  trust_device: { args: { deviceId: SEED_DEVICE_ID }, accept: { ok: true } },
  mute_device: { args: { deviceId: SEED_DEVICE_ID }, accept: { ok: true } },
  flag_device: { args: { deviceId: SEED_DEVICE_ID }, accept: { ok: true } },
  clear_device_mark: { args: { deviceId: SEED_DEVICE_ID }, accept: { ok: true } },
  scan_storage: {
    // Scanner presence is environment-dependent: a real ClamAV yields a running
    // scan; no scanner yields the stable scanner_unavailable. Both are mapped.
    args: { volumePath: "/tmp/plugsight-roundtrip-nonexistent-volume" },
    accept: { ok: true, kinds: ["scanner_unavailable"] },
  },
  cancel_scan: { args: { scanId: MISSING }, accept: { kinds: ["not_found"] } },
  restore_quarantine: {
    // No confirm:true -> the adapter's deliberate-act guard fires (invalid_params)
    // before any daemon call. This is the charter's confirm gate (docs/spec/03).
    args: { quarantineId: MISSING },
    accept: { kinds: ["invalid_params"] },
  },
  set_policy: { args: { scanOnMount: false }, accept: { ok: true } },
};

/** Classify one tool result against its expectation. Returns { pass, detail }.
 * On a SUCCESS, the structured content is additionally validated against the
 * tool's declared zod OUTPUT schema — so a daemon response that no longer
 * satisfies the tool's canonical shape FAILS the round-trip (not just an
 * unmapped-error check). */
function classify(tool, result) {
  const name = tool.name;
  const exp = EXPECTATIONS[name];
  const okAllowed = exp.accept.ok === true;
  const kindsAllowed = exp.accept.kinds ?? [];

  if (result.isError) {
    const err = result.structuredContent?.error;
    const kind = err?.kind;
    if (!kind || !STABLE_KINDS.has(kind)) {
      return { pass: false, detail: `unmapped error kind ${JSON.stringify(kind)}` };
    }
    if (!kindsAllowed.includes(kind)) {
      const want = okAllowed
        ? `ok${kindsAllowed.length ? ` or error(${kindsAllowed.join("|")})` : ""}`
        : `error(${kindsAllowed.join("|")})`;
      return {
        pass: false,
        detail: `got error(${kind}) but expected ${want} — ${err.message}`,
      };
    }
    return { pass: true, detail: `error(${kind}) [expected]` };
  }

  // A success result.
  if (!okAllowed) {
    return {
      pass: false,
      detail: `got success but expected error(${kindsAllowed.join("|")})`,
    };
  }
  if (typeof result.structuredContent !== "object" || result.structuredContent === null) {
    return { pass: false, detail: "success result carried no structuredContent object" };
  }
  if (exp.check) {
    const problem = exp.check(result);
    if (problem) return { pass: false, detail: problem };
  }
  // ZOD SHAPE PARITY: the REAL daemon's response must satisfy the tool's declared
  // output schema. A field rename/removal in the daemon fails HERE.
  if (tool.outputSchema && typeof tool.outputSchema.safeParse === "function") {
    const parsed = tool.outputSchema.safeParse(result.structuredContent);
    if (!parsed.success) {
      const first = parsed.error.issues[0];
      const where = first?.path?.length ? first.path.join(".") : "(root)";
      return {
        pass: false,
        detail: `daemon response failed the tool's zod output schema at '${where}': ${first?.message}`,
      };
    }
    return { pass: true, detail: "ok (zod output-shape validated)" };
  }
  return { pass: true, detail: "ok" };
}

// MARK: - Main

async function main() {
  // 1. Build the daemon.
  log("== build ==");
  log("swift build (repo root)…");
  const build = spawnSync("swift", ["build"], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (build.status !== 0) {
    log(build.stdout || "");
    log(build.stderr || "");
    throw new Error(`swift build failed (status ${build.status}).`);
  }
  if (!fs.existsSync(DAEMON_BIN)) {
    throw new Error(`Daemon binary not found at ${DAEMON_BIN} after swift build.`);
  }
  log(`daemon binary: ${DAEMON_BIN}`);

  // Temp workspace.
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "plugsight-roundtrip-"));
  const dbPath = path.join(workDir, "seed.db");
  const stateDir = path.join(workDir, "state");
  fs.mkdirSync(stateDir, { recursive: true });

  let hadFailure = false;

  try {
    // 2a. First boot: let GRDB create + migrate the schema, then stop.
    log("\n== seed ==");
    log("boot #1 (migrate schema)…");
    await withDaemon(dbPath, stateDir, async () => {
      /* readiness == migration complete; nothing else to do here */
    });
    // 2b. Seed one device while the DB is released.
    seedDevice(dbPath);
    log(`seeded device ${SEED_DEVICE_ID} into ${dbPath}`);

    // 3. Second boot: serve the seeded state and drive every tool. Managed
    //    explicitly (not via withDaemon) so we can assert a clean SIGTERM exit.
    log("\n== round-trip ==");
    log("boot #2 (serve seeded state)…");
    const daemon = spawnDaemon(dbPath, stateDir);
    try {
      await Promise.race([
        waitForDaemonFiles(stateDir),
        daemon.exited.then((e) => {
          throw new Error(
            `Daemon exited before becoming ready (code=${e.code}, signal=${e.signal}).\n${daemon.output}`,
          );
        }),
      ]);
      if (daemon.spawnError) throw daemon.spawnError;

      const client = new PlugsightClient({
        baseDir: stateDir,
        clientInfo: { name: "roundtrip", kind: "mcp" },
      });

      // auth.hello + version negotiation.
      const hello = await client.connect();
      log(
        `auth.hello ok — apiVersion ${hello.apiVersion}, daemon ${hello.daemonVersion}, ` +
          `clamav=${hello.capabilities.clamav}\n`,
      );

      let pass = 0;
      let fail = 0;
      // Drive the 19 tools in their declared order.
      for (const tool of TOOLS) {
        const exp = EXPECTATIONS[tool.name];
        if (!exp) {
          log(`FAIL  ${tool.name.padEnd(20)} no expectation defined for this tool`);
          fail++;
          continue;
        }
        let result;
        try {
          result = await Promise.race([
            executeTool(client, tool, exp.args),
            sleep(20_000).then(() => {
              throw new Error("tool call timed out after 20s");
            }),
          ]);
        } catch (e) {
          // A throw OUT of executeTool means an unmapped error (executeTool maps
          // every PlugsightError to a structured tool error) — a hard failure.
          log(`FAIL  ${tool.name.padEnd(20)} unmapped exception: ${e?.message ?? e}`);
          fail++;
          continue;
        }
        const { pass: ok, detail } = classify(tool, result);
        log(`${ok ? "PASS" : "FAIL"}  ${tool.name.padEnd(20)} ${detail}`);
        if (ok) pass++;
        else fail++;
      }

      client.close();
      log(`\n${pass}/${TOOLS.length} tools passed; ${fail} failed.`);
      if (fail > 0) hadFailure = true;

      // 4. Clean shutdown: SIGTERM -> daemon.stopped -> exit(0).
      log("\n== shutdown ==");
      const exit = await daemon.stop();
      if (exit.killedHard) {
        log("FAIL  shutdown          daemon ignored SIGTERM; had to SIGKILL");
        hadFailure = true;
      } else if (exit.code === 0) {
        log("PASS  shutdown          daemon exited 0 on SIGTERM (clean stop)");
      } else {
        log(
          `FAIL  shutdown          daemon exited code=${exit.code} signal=${exit.signal} (expected clean exit 0)`,
        );
        hadFailure = true;
      }
    } finally {
      // Belt and suspenders: never leave the daemon running.
      await daemon.stop();
    }
  } finally {
    // Cleanup temp workspace.
    try {
      fs.rmSync(workDir, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
  }

  if (hadFailure) {
    log("\nRESULT: FAIL — at least one tool did not round-trip cleanly.");
    process.exit(1);
  }
  log("\nRESULT: PASS — all 19 tools round-tripped to a mapped result/error.");
  process.exit(0);
}

main().catch((e) => {
  log(`\nRESULT: ERROR — ${e?.stack ?? e}`);
  process.exit(1);
});
