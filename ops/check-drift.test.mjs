#!/usr/bin/env node
// ops/check-drift.test.mjs — the drift gate's own verify gate (N14).
//
// It proves the gate has teeth: it points `runGate` at DELIBERATELY DRIFTED
// README fixtures and asserts the gate FAILS (exit 1) for each, then runs the
// gate against the REAL tree and asserts it PASSES (exit 0). It also proves the
// `plugsightd --print-catalog` path works end to end.
//
// Run: `node ops/check-drift.test.mjs` — exits 0 iff every assertion holds.

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { parseArgs, runGate } from "./check-drift.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..");
const REAL_README = join(ROOT, "README.md");

let passed = 0;
let failed = 0;
function check(name, cond) {
  if (cond) { passed++; console.log(`  ok   ${name}`); }
  else { failed++; console.log(`  FAIL ${name}`); }
}

// --- Capture the real event-kind catalog once, so drift runs are fast and do
// --- not rebuild. This also exercises the `--print-catalog` flag path.
const bin = existsSync(join(ROOT, ".build/release/plugsightd"))
  ? join(ROOT, ".build/release/plugsightd")
  : join(ROOT, ".build/debug/plugsightd");
let catalogRaw;
try {
  catalogRaw = execFileSync(bin, ["--print-catalog"], { encoding: "utf8" });
} catch {
  console.log(`  (building plugsightd first — no prebuilt binary at ${bin})`);
  execFileSync("swift", ["build", "--product", "plugsightd"], { cwd: ROOT, stdio: "inherit" });
  catalogRaw = execFileSync(join(ROOT, ".build/debug/plugsightd"), ["--print-catalog"], { encoding: "utf8" });
}
const catalog = JSON.parse(catalogRaw);
check("--print-catalog emits a non-empty eventKinds array", Array.isArray(catalog.eventKinds) && catalog.eventKinds.length > 0);
check("--print-catalog count matches array length", catalog.eventKindCount === catalog.eventKinds.length);

const work = mkdtempSync(join(tmpdir(), "plugsight-drift-"));
const catalogJson = join(work, "catalog.json");
writeFileSync(catalogJson, catalogRaw);

function baseOpts(readmePath) {
  return {
    root: ROOT,
    readme: readmePath,
    tools: join(ROOT, "mcp/contract/tools.json"),
    mcpSrc: join(ROOT, "mcp/src"),
    doc03: join(ROOT, "docs/spec/03-mcp-interface.md"),
    website: undefined,
    plugsightd: null,
    catalogJson,
    quiet: true,
  };
}

function fixtureReadme(name, mutate) {
  const text = mutate(readFileSync(REAL_README, "utf8"));
  const p = join(work, `README.${name}.md`);
  writeFileSync(p, text);
  return p;
}

// --- Drift 1: a tool row REMOVED from the README capability table (missing row).
const missingTool = fixtureReadme("missing-tool", (t) =>
  t.replace(/^\| `get_status` \| no \|.*\n/m, "")
);
check("real tree has the get_status row to remove", missingTool !== REAL_README);
check("DRIFT missing tool row → gate FAILS", runGate(baseOpts(missingTool)) === 1);

// --- Drift 2: a PHANTOM tool row added to the README capability table.
const phantomTool = fixtureReadme("phantom-tool", (t) =>
  t.replace(
    "<!-- END:capability-tools -->",
    "| `nuke_device` | yes | Phantom tool that does not exist. |\n\n<!-- END:capability-tools -->"
  )
);
check("DRIFT phantom tool row → gate FAILS", runGate(baseOpts(phantomTool)) === 1);

// --- Drift 3: an event kind REMOVED from the README event-kind list.
const missingKind = fixtureReadme("missing-kind", (t) =>
  t.replace("- `monitoring.gap`\n", "")
);
check("DRIFT missing event kind → gate FAILS", runGate(baseOpts(missingKind)) === 1);

// --- Drift 4: a PHANTOM event kind added to the README event-kind list.
const phantomKind = fixtureReadme("phantom-kind", (t) =>
  t.replace(
    "<!-- END:capability-event-kinds -->",
    "- `cable.exploded`\n\n<!-- END:capability-event-kinds -->"
  )
);
check("DRIFT phantom event kind → gate FAILS", runGate(baseOpts(phantomKind)) === 1);

// --- Drift 5: a banned marketing claim added to the README (bare, not quoted).
const bannedClaim = fixtureReadme("banned-claim", (t) =>
  t.replace("## License", "Plugsight blocks BadUSB attacks and prevents rogue keyboards.\n\n## License")
);
check("DRIFT banned claim (bare) → gate FAILS", runGate(baseOpts(bannedClaim)) === 1);

// --- Control: a banned WORD inside a quoted negation must still PASS.
const quotedNegation = fixtureReadme("quoted-negation", (t) =>
  t.replace("## License", 'Plugsight never "blocks" a device — it is not a blocker.\n\n## License')
);
check("CONTROL quoted-negation banned word → gate PASSES", runGate(baseOpts(quotedNegation)) === 0);

// --- Drift 6: a stated tool count that disagrees with the contract (the
// --- recurring "stale-doc-tool-count" class this guard promotes). Injected into
// --- the README prose (scanned via opts.readme), digit and spelled forms both.
const wrongCountDigit = fixtureReadme("wrong-count-digit", (t) =>
  t.replace("## License", "Plugsight exposes 18 tools.\n\n## License")
);
check("DRIFT stated count '18 tools' → gate FAILS", runGate(baseOpts(wrongCountDigit)) === 1);

const wrongCountSpelled = fixtureReadme("wrong-count-spelled", (t) =>
  t.replace("## License", "Plugsight exposes Eighteen tools.\n\n## License")
);
check("DRIFT stated count 'Eighteen tools' → gate FAILS", runGate(baseOpts(wrongCountSpelled)) === 1);

// --- Control: the CORRECT stated count must still PASS.
const rightCount = fixtureReadme("right-count", (t) =>
  t.replace("## License", "Plugsight exposes 19 tools.\n\n## License")
);
check("CONTROL stated count '19 tools' → gate PASSES", runGate(baseOpts(rightCount)) === 0);

// --- Website banned-claims scan: the marketing site lives in web/, and the gate
// --- MUST scan it. Two facts to prove: (a) with no --website flag, parseArgs
// --- DEFAULTS opts.website to the real web/ dir — the gap this covers, since it
// --- used to guess a non-existent website/ and so scanned nothing; and (b) a bare
// --- banned claim planted in a web-style *.html file is caught.

// (a) Default resolution points at web/ (not the legacy website/ guess).
const defaultWebsite = parseArgs(["node", "check-drift.mjs", "--root", ROOT]).website;
check("default --website resolves to the real web/ dir", defaultWebsite === join(ROOT, "web"));

// (b) A bare banned claim in a web/*.html fixture makes the gate FAIL.
const evilWeb = mkdtempSync(join(tmpdir(), "plugsight-web-"));
writeFileSync(
  join(evilWeb, "index.html"),
  "<!doctype html><html><body><p>Plugsight blocks BadUSB and prevents rogue keyboards.</p></body></html>\n"
);
check("DRIFT banned claim in web/*.html → gate FAILS",
  runGate({ ...baseOpts(REAL_README), website: evilWeb }) === 1);

// Control: the REAL, honest web/ copy passes when scanned.
check("CONTROL real web/ copy scanned → gate PASSES",
  runGate({ ...baseOpts(REAL_README), website: join(ROOT, "web") }) === 0);

// --- The real tree must be GREEN (both via captured catalog and via the live flag).
check("REAL tree (captured catalog) → gate PASSES", runGate(baseOpts(REAL_README)) === 0);
check("REAL tree (live --print-catalog) → gate PASSES",
  runGate({ ...baseOpts(REAL_README), catalogJson: null }) === 0);

console.log(`\ncheck-drift.test: ${passed} passed, ${failed} failed.`);
process.exit(failed === 0 ? 0 : 1);
