#!/usr/bin/env node
// ops/check-drift.mjs — the capability drift gate (docs/spec/08, "The capability
// drift gate"; N14).
//
// It exists so the README, the website, and the docs can never claim more (or
// less) than the software does. On every push (CI) and before every release it:
//
//   1. Reads mcp/contract/tools.json (the registered tools, 03) and asserts the
//      count is exactly 19.
//   2. Runs `plugsightd --print-catalog` (the closed set of event kinds the
//      daemon emits, 06) — the canonical EventKindCatalog, one place in Swift.
//   3. Verifies the README capability table AND the 03 tool inventory list
//      EXACTLY those 19 tools — no missing rows, no phantom rows.
//   4. Verifies the README event-kind list is EXACTLY the daemon's catalog.
//   5. Charter greps: the score caveat string exists in the MCP source (03);
//      the banned-claims list ("blocks", "prevents", "stops BadUSB", "detects
//      malicious cables") does NOT appear in README/website copy outside a
//      quoted negation.
//
// On any drift it prints a diff-shaped message naming the drifted line and exits
// non-zero; otherwise it prints a green summary and exits 0.
//
// Crude on purpose (08): a grep that cries wolf occasionally is cheaper than a
// marketing claim that lies once.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = resolve(HERE, "..");

const EXPECTED_TOOL_COUNT = 19;

// ---------------------------------------------------------------------------
// Stated-tool-count scan (kaizen guard: class "stale-doc-tool-count").
//
// Doc count-drift recurred: round 1 shipped "18 MCP tools" in spec/07 while the
// contract had 19 (it escaped because this gate only scanned README + spec/03).
// This scans EVERY shipped doc for a stated MCP-tool count and fails if any
// number disagrees with the canonical count derived from mcp/contract/tools.json
// (never hardcoded here). Matches digit forms ("19 tools", "19-tool", "18 MCP
// tools") and the spelled forms the specs actually use ("Nineteen tools",
// lowercase "nineteen tools"), mapping spelled -> integer for comparison.
// ---------------------------------------------------------------------------
const SPELLED_TO_INT = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7,
  eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12, thirteen: 13,
  fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18,
  nineteen: 19, twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60,
  seventy: 70, eighty: 80, ninety: 90,
};

// Number sub-pattern: 1-3 digits, or an English cardinal word / "tens-unit"
// compound (twenty-one, forty five). Ordered so teens beat the bare unit ("nine"
// inside "nineteen") and tens+unit is tried before a bare tens word.
const TENS = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety";
const TEENS = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen";
const ONES = "one|two|three|four|five|six|seven|eight|nine";
const NUM = `\\d{1,3}|(?:${TENS})(?:[\\s-](?:${ONES}))?|${TEENS}|${ONES}`;
// A tool-count claim: a number, then optional "MCP", then tool(s). Handles the
// hyphenated singular "19-tool round-trip" as well as "19 tools" / "Nineteen tools".
const TOOL_COUNT_RE = new RegExp(`\\b(${NUM})[\\s-]+(?:MCP[\\s-]+)?tools?\\b`, "gi");

/** Parse a matched number token (digits or spelled) to an integer, or null. */
function parseCount(tokenRaw) {
  const token = tokenRaw.trim().toLowerCase();
  if (/^\d{1,3}$/.test(token)) return parseInt(token, 10);
  let total = 0;
  for (const part of token.split(/[\s-]+/)) {
    if (!(part in SPELLED_TO_INT)) return null;
    total += SPELLED_TO_INT[part];
  }
  return total;
}

/**
 * Scan the given docs for stated MCP-tool counts. Any count != canonical is a
 * problem line naming file:line, the offending claim, and the expected count.
 */
function scanToolCountClaims(files, canonical, root) {
  const problems = [];
  for (const file of files) {
    if (!existsSync(file)) continue;
    const rel = file.startsWith(root + "/") ? file.slice(root.length + 1) : file;
    const lines = readFileSync(file, "utf8").split("\n");
    lines.forEach((line, idx) => {
      TOOL_COUNT_RE.lastIndex = 0;
      let m;
      while ((m = TOOL_COUNT_RE.exec(line)) !== null) {
        const stated = parseCount(m[1]);
        if (stated === null || stated === canonical) continue;
        problems.push(
          `${rel}:${idx + 1}: stated tool count ${stated} (\"${m[0].trim()}\") ` +
          `!= canonical ${canonical} (from mcp/contract/tools.json)\n` +
          `      > ${line.trim()}`
        );
      }
    });
  }
  return problems;
}

// The canonical score caveat sentence (03; charter item 4/7). Must appear in the
// MCP source verbatim.
const SCORE_CAVEAT = "Behavioral scoring is probabilistic and a patient attacker can evade it.";

// The banned marketing claims (08). Matched case-insensitively. Allowed ONLY
// inside a quoted negation (the honest README saying it does NOT do these).
const BANNED_CLAIMS = [
  { label: "blocks", re: /\bblocks\b/gi },
  { label: "prevents", re: /\bprevents\b/gi },
  { label: "stops BadUSB", re: /stops\s+badusb/gi },
  { label: "detects malicious cables", re: /detects\s+malicious\s+cables/gi },
];

const NEGATION = /\b(not|never|no|cannot|can't|won't|doesn't|does not|do not|without)\b/i;

// ---------------------------------------------------------------------------
// Option parsing (kept tiny; the self-test drives it with fixture overrides).
// ---------------------------------------------------------------------------
export function parseArgs(argv) {
  const opts = {
    root: DEFAULT_ROOT,
    readme: null,
    tools: null,
    mcpSrc: null,
    doc03: null,
    website: null, // optional dir of website copy
    plugsightd: null, // path to the built binary
    catalogJson: null, // OR a captured --print-catalog JSON file (used by the self-test)
    quiet: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case "--root": opts.root = resolve(next()); break;
      case "--readme": opts.readme = resolve(next()); break;
      case "--tools": opts.tools = resolve(next()); break;
      case "--mcp-src": opts.mcpSrc = resolve(next()); break;
      case "--doc03": opts.doc03 = resolve(next()); break;
      case "--website": opts.website = resolve(next()); break;
      case "--plugsightd": opts.plugsightd = resolve(next()); break;
      case "--catalog-json": opts.catalogJson = resolve(next()); break;
      case "--quiet": opts.quiet = true; break;
      default:
        throw new Error(`unknown argument: ${a}`);
    }
  }
  opts.readme ??= join(opts.root, "README.md");
  opts.tools ??= join(opts.root, "mcp/contract/tools.json");
  opts.mcpSrc ??= join(opts.root, "mcp/src");
  opts.doc03 ??= join(opts.root, "docs/spec/03-mcp-interface.md");
  if (opts.website === null) {
    // The marketing site lives in web/ (index.html, styles.css); older layouts
    // used website/. Prefer web/, fall back to website/, else scan nothing. This
    // default is what every gate invocation (ops/gate.sh, ops/release.mjs) relies
    // on, since none pass --website.
    const webDir = join(opts.root, "web");
    const legacyDir = join(opts.root, "website");
    opts.website = existsSync(webDir) ? webDir
      : existsSync(legacyDir) ? legacyDir
      : undefined;
  }
  return opts;
}

// ---------------------------------------------------------------------------
// Extractors
// ---------------------------------------------------------------------------
function sectionBetween(text, beginNeedle, endNeedle, label) {
  const b = text.indexOf(beginNeedle);
  const e = text.indexOf(endNeedle);
  if (b < 0) throw new Error(`could not find "${beginNeedle}" anchor for ${label}`);
  if (e < 0 || e < b) throw new Error(`could not find "${endNeedle}" anchor for ${label}`);
  return text.slice(b + beginNeedle.length, e);
}

/** First backticked snake_case token of each markdown table row (the tool column). */
function tableFirstColumnTokens(regionText) {
  const out = [];
  for (const line of regionText.split("\n")) {
    const m = line.match(/^\s*\|\s*`([a-z][a-z0-9_]*)`/);
    if (m) out.push(m[1]);
  }
  return out;
}

/** Backticked token of each markdown bullet line (an event-kind entry). */
function bulletTokens(regionText) {
  const out = [];
  for (const line of regionText.split("\n")) {
    const m = line.match(/^\s*-\s*`([a-z][a-z0-9_.]*)`/);
    if (m) out.push(m[1]);
  }
  return out;
}

/** Extract the 03 "## Tool inventory" table's first column (tool names). */
function doc03ToolInventory(text) {
  const heading = "## Tool inventory";
  const start = text.indexOf(heading);
  if (start < 0) throw new Error(`could not find "${heading}" in 03`);
  const rest = text.slice(start + heading.length);
  const nextHeading = rest.search(/\n## /);
  const region = nextHeading < 0 ? rest : rest.slice(0, nextHeading);
  return tableFirstColumnTokens(region);
}

// ---------------------------------------------------------------------------
// Set comparison → diff-shaped lines
// ---------------------------------------------------------------------------
/**
 * Compare a `declared` list (what a doc says) against the `truth` list (what the
 * software registers). Returns an array of diff-shaped problem lines:
 *   `- name` : in truth, missing from the doc.
 *   `+ name` : in the doc, not in truth (phantom).
 * Also flags duplicate rows in the doc.
 */
function diffSets(truth, declared, { truthWhere, docWhere }) {
  const problems = [];
  const truthSet = new Set(truth);
  const declaredSet = new Set(declared);

  // Duplicate rows in the doc.
  const seen = new Set();
  for (const name of declared) {
    if (seen.has(name)) problems.push(`! ${name}   (listed twice in ${docWhere})`);
    seen.add(name);
  }
  for (const name of truth) {
    if (!declaredSet.has(name)) {
      problems.push(`- ${name}   (registered in ${truthWhere}, missing from ${docWhere})`);
    }
  }
  for (const name of declared) {
    if (!truthSet.has(name)) {
      problems.push(`+ ${name}   (listed in ${docWhere}, not registered in ${truthWhere})`);
    }
  }
  return problems;
}

// ---------------------------------------------------------------------------
// Banned-claims scan
// ---------------------------------------------------------------------------
function quotedSpans(line) {
  const spans = [];
  const re = /"[^"]*"|'[^']*'|“[^”]*”|‘[^’]*’/g;
  let m;
  while ((m = re.exec(line)) !== null) {
    spans.push([m.index, m.index + m[0].length]);
  }
  return spans;
}

function scanBannedClaims(filePath, relLabel) {
  const problems = [];
  const text = readFileSync(filePath, "utf8");
  const lines = text.split("\n");
  lines.forEach((line, idx) => {
    const spans = quotedSpans(line);
    for (const { label, re } of BANNED_CLAIMS) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(line)) !== null) {
        const at = m.index;
        const inQuote = spans.some(([s, e]) => at >= s && at < e);
        const negated = NEGATION.test(line);
        // Allowed only as a quoted negation.
        if (inQuote && negated) continue;
        problems.push(
          `${relLabel}:${idx + 1}: banned claim "${label}" outside a quoted negation\n` +
          `      > ${line.trim()}`
        );
      }
    }
  });
  return problems;
}

// ---------------------------------------------------------------------------
// Event-kind catalog: run the daemon flag, or read a captured JSON (self-test).
// ---------------------------------------------------------------------------
function loadEventKinds(opts) {
  let raw;
  if (opts.catalogJson) {
    raw = readFileSync(opts.catalogJson, "utf8");
  } else {
    const bin = opts.plugsightd || findPlugsightd(opts.root);
    raw = execFileSync(bin, ["--print-catalog"], { encoding: "utf8" });
  }
  const parsed = JSON.parse(raw);
  const kinds = parsed.eventKinds;
  if (!Array.isArray(kinds)) throw new Error("--print-catalog output has no eventKinds array");
  if (typeof parsed.eventKindCount === "number" && parsed.eventKindCount !== kinds.length) {
    throw new Error(
      `--print-catalog: eventKindCount ${parsed.eventKindCount} != actual ${kinds.length}`
    );
  }
  return kinds;
}

function findPlugsightd(root) {
  const candidates = [
    join(root, ".build/release/plugsightd"),
    join(root, ".build/debug/plugsightd"),
  ];
  for (const c of candidates) if (existsSync(c)) return c;
  // Build it. (The gate "builds it first or accepts a path", 08.)
  process.stderr.write("check-drift: plugsightd not built; running `swift build --product plugsightd`...\n");
  execFileSync("swift", ["build", "--product", "plugsightd"], { cwd: root, stdio: "inherit" });
  return join(root, ".build/debug/plugsightd");
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------
export function runGate(opts) {
  const problems = [];
  const log = (s) => { if (!opts.quiet) process.stdout.write(s + "\n"); };

  // 1. Registered tools (truth).
  const contract = JSON.parse(readFileSync(opts.tools, "utf8"));
  const registeredTools = contract.tools.map((t) => t.name);
  if (contract.toolCount !== EXPECTED_TOOL_COUNT || registeredTools.length !== EXPECTED_TOOL_COUNT) {
    problems.push(
      `! tool count drift: contract declares ${contract.toolCount}, has ${registeredTools.length} ` +
      `tool rows, gate expects ${EXPECTED_TOOL_COUNT}`
    );
  }

  // 2. Event kinds (truth).
  const catalogKinds = loadEventKinds(opts);

  // 3a. README capability table vs registered tools.
  const readme = readFileSync(opts.readme, "utf8");
  const toolRegion = sectionBetween(
    readme,
    "<!-- BEGIN:capability-tools",
    "<!-- END:capability-tools -->",
    "README capability table"
  );
  const readmeTools = tableFirstColumnTokens(toolRegion);
  problems.push(...diffSets(registeredTools, readmeTools, {
    truthWhere: "mcp/contract/tools.json",
    docWhere: "README capability table",
  }));

  // 3b. docs/spec/03 tool inventory vs registered tools.
  const doc03 = readFileSync(opts.doc03, "utf8");
  const doc03Tools = doc03ToolInventory(doc03);
  problems.push(...diffSets(registeredTools, doc03Tools, {
    truthWhere: "mcp/contract/tools.json",
    docWhere: "docs/spec/03 tool inventory",
  }));

  // 3c. Stated tool counts across EVERY shipped doc must equal the canonical
  //     count derived from the contract (registeredTools.length), not a literal.
  const canonicalToolCount = registeredTools.length;
  const docSpecDir = join(opts.root, "docs/spec");
  const specDocs = existsSync(docSpecDir)
    ? fsReaddir(docSpecDir).filter((f) => f.endsWith(".md")).sort().map((f) => join(docSpecDir, f))
    : [];
  const countDocs = [
    opts.readme, // honors --readme (and the self-test's fixture override)
    join(opts.root, "CHANGELOG.md"),
    join(opts.root, "docs/BUILD-STATUS.md"),
    ...specDocs,
  ];
  problems.push(...scanToolCountClaims(countDocs, canonicalToolCount, opts.root));

  // 4. README event-kind list vs the daemon's catalog.
  const kindRegion = sectionBetween(
    readme,
    "<!-- BEGIN:capability-event-kinds",
    "<!-- END:capability-event-kinds -->",
    "README event-kind list"
  );
  const readmeKinds = bulletTokens(kindRegion);
  problems.push(...diffSets(catalogKinds, readmeKinds, {
    truthWhere: "plugsightd --print-catalog",
    docWhere: "README event-kind list",
  }));

  // 5a. Score caveat must exist in the MCP source.
  const caveatFound = grepDir(opts.mcpSrc, SCORE_CAVEAT);
  if (!caveatFound) {
    problems.push(
      `! score caveat string missing from MCP source (${opts.mcpSrc}):\n` +
      `      expected: ${SCORE_CAVEAT}`
    );
  }

  // 5b. Banned claims in README + website copy.
  problems.push(...scanBannedClaims(opts.readme, "README.md"));
  if (opts.website) {
    for (const f of listCopyFiles(opts.website)) {
      problems.push(...scanBannedClaims(f, f.replace(opts.root + "/", "")));
    }
  }

  if (problems.length > 0) {
    log("");
    log("CAPABILITY DRIFT DETECTED — the docs and the software disagree:");
    log("  (- missing from docs, + phantom in docs, ! structural, plus charter grep failures)");
    log("");
    for (const p of problems) log("  " + p);
    log("");
    log(`check-drift: FAIL (${problems.length} problem${problems.length === 1 ? "" : "s"}).`);
    return 1;
  }

  log("check-drift: OK");
  log(`  tools:       ${registeredTools.length} registered == README == 03 inventory == every shipped doc's stated count`);
  log(`  event kinds: ${catalogKinds.length} from --print-catalog == README list`);
  log(`  charter:     score caveat present; no banned claims outside quoted negations`);
  return 0;
}

function grepDir(dir, needle) {
  if (!existsSync(dir)) return false;
  const stack = [dir];
  const { readdirSync, statSync } = fsSync();
  while (stack.length) {
    const cur = stack.pop();
    for (const entry of readdirSync(cur)) {
      const full = join(cur, entry);
      const st = statSync(full);
      if (st.isDirectory()) { stack.push(full); continue; }
      if (!/\.(ts|js|mjs|tsx)$/.test(entry)) continue;
      if (readFileSync(full, "utf8").includes(needle)) return true;
    }
  }
  return false;
}

function listCopyFiles(dir) {
  const out = [];
  const { readdirSync, statSync } = fsSync();
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop();
    for (const entry of readdirSync(cur)) {
      const full = join(cur, entry);
      const st = statSync(full);
      if (st.isDirectory()) { stack.push(full); continue; }
      if (/\.(md|html|txt)$/.test(entry)) out.push(full);
    }
  }
  return out;
}

function fsSync() {
  // Lazy import to keep the top clean; readdirSync/statSync are the only extras.
  return { readdirSync: fsReaddir, statSync: fsStat };
}

// Bind the two extra fs calls once.
import { readdirSync as fsReaddir, statSync as fsStat } from "node:fs";

// ---------------------------------------------------------------------------
// CLI entry (only when run directly, not when imported by the self-test).
// ---------------------------------------------------------------------------
const isMain = resolve(process.argv[1] || "") === resolve(fileURLToPath(import.meta.url));
if (isMain) {
  const opts = parseArgs(process.argv);
  process.exit(runGate(opts));
}
