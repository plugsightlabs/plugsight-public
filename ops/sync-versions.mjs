#!/usr/bin/env node
// ops/sync-versions.mjs — propagate the single source of truth.
//
// `ops/version.json` is the one place a human bumps the version (docs/spec/08:
// "the single source all targets read"). This script pushes that value into the
// targets that carry their own copy and cannot read the JSON at runtime:
//
//   • mcp/package.json            (the npm package version)
//   • mcp/src/server.ts           (SERVER_VERSION, advertised over MCP initialize)
//   • Sources/plugsightd/main.swift  (the daemon's reported `daemonVersion`)
//
// The release pipeline (ops/release.mjs) VALIDATES that all three agree and is
// fatal on mismatch; this script is the mechanical way to make them agree after
// editing ops/version.json. Run it, review the diff, commit.
//
// Usage:
//   node ops/sync-versions.mjs           # write the targets from version.json
//   node ops/sync-versions.mjs --check   # exit non-zero if any target drifted
//
// No secrets, no network — pure text rewrite in-tree.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const OPS = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(OPS);

const VERSION_JSON = join(OPS, "version.json");
const MCP_PKG = join(ROOT, "mcp", "package.json");
const MCP_SERVER = join(ROOT, "mcp", "src", "server.ts");
const DAEMON_MAIN = join(ROOT, "Sources", "plugsightd", "main.swift");

// The daemon constant is a single, unambiguous line: `let daemonVersion = "X"`.
const DAEMON_RE = /let\s+daemonVersion\s*=\s*"([^"]+)"/;
// The MCP server constant: `export const SERVER_VERSION = "X"` (advertised on
// initialize). SERVER_NAME is a sibling `export const`, so anchor on the name.
const SERVER_RE = /export const SERVER_VERSION\s*=\s*"([^"]+)"/;

const check = process.argv.includes("--check");

function readVersion() {
  const raw = readFileSync(VERSION_JSON, "utf8");
  const parsed = JSON.parse(raw);
  if (typeof parsed.version !== "string" || !parsed.version.trim()) {
    throw new Error(`ops/version.json has no usable "version" string`);
  }
  return parsed.version.trim();
}

/** @returns {boolean} true if the file already matched (no write needed) */
function syncMcpPackage(version) {
  const raw = readFileSync(MCP_PKG, "utf8");
  const pkg = JSON.parse(raw);
  if (pkg.version === version) return true;
  if (check) {
    console.error(`  DRIFT mcp/package.json version ${pkg.version} != ${version}`);
    return false;
  }
  pkg.version = version;
  // Preserve two-space indentation + trailing newline (matches the repo style).
  writeFileSync(MCP_PKG, JSON.stringify(pkg, null, 2) + "\n");
  console.log(`  wrote mcp/package.json version -> ${version}`);
  return true;
}

/** @returns {boolean} true if the file already matched (no write needed) */
function syncServer(version) {
  const raw = readFileSync(MCP_SERVER, "utf8");
  const m = raw.match(SERVER_RE);
  if (!m) throw new Error(`could not find 'export const SERVER_VERSION = "..."' in ${MCP_SERVER}`);
  if (m[1] === version) return true;
  if (check) {
    console.error(`  DRIFT mcp SERVER_VERSION ${m[1]} != ${version}`);
    return false;
  }
  const next = raw.replace(SERVER_RE, `export const SERVER_VERSION = "${version}"`);
  writeFileSync(MCP_SERVER, next);
  console.log(`  wrote mcp SERVER_VERSION -> ${version}`);
  return true;
}

/** @returns {boolean} true if the file already matched (no write needed) */
function syncDaemon(version) {
  const raw = readFileSync(DAEMON_MAIN, "utf8");
  const m = raw.match(DAEMON_RE);
  if (!m) throw new Error(`could not find 'let daemonVersion = "..."' in ${DAEMON_MAIN}`);
  if (m[1] === version) return true;
  if (check) {
    console.error(`  DRIFT plugsightd daemonVersion ${m[1]} != ${version}`);
    return false;
  }
  const next = raw.replace(DAEMON_RE, `let daemonVersion = "${version}"`);
  writeFileSync(DAEMON_MAIN, next);
  console.log(`  wrote plugsightd daemonVersion -> ${version}`);
  return true;
}

function main() {
  const version = readVersion();
  console.log(`${check ? "checking" : "syncing"} all targets against ops/version.json = ${version}`);
  const okMcp = syncMcpPackage(version);
  const okServer = syncServer(version);
  const okDaemon = syncDaemon(version);
  if (check && !(okMcp && okServer && okDaemon)) {
    console.error("version drift: run `node ops/sync-versions.mjs` and commit");
    process.exit(1);
  }
  console.log(check ? "versions consistent" : "done");
}

main();
