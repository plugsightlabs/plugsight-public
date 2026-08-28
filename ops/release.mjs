#!/usr/bin/env node
// ops/release.mjs — the one-command ship pipeline (docs/spec/08, "The ship
// pipeline"). Seven steps, in order, each FATAL on failure:
//
//   1. Preflight   clean tree on `main`; version.json; changelog entry; version
//                  consistency across version.json / mcp / daemon.
//   2. Gates       swift test, mcp test, seam gate, secret scan, drift gate.
//   3. Build       release-config plugsightd + app; assemble Plugsight.app.
//   4. Sign+package+notarize+staple   codesign daemon/ES/app, build the dmg
//                  FROM the signed app, codesign the dmg, notarize + staple it.
//   5. npm publish  @plugsight/mcp --provenance (apiVersion compat asserted).
//   6. GitHub release   tag, gh release create, dmg upload, changelog body.
//   7. Post-flight  fresh dmg, spctl, npx @plugsight/mcp@latest -> get_status.
//
// The dmg is assembled AFTER the app bundle is codesigned, so the shipped dmg
// always carries the SIGNED app. An earlier version built the dmg in step 3
// from an unsigned bundle, which would fail notarization / trip Gatekeeper.
//
// `--dry-run` runs steps 1-3 FOR REAL (preflight + gates + build) and, in step
// 4, PRINTS the signing as "would run" but still assembles the (unsigned) dmg
// so the build artifact exists; it PRINTS steps 5-7 as "would run" without
// doing them (no notarization submit, no npm publish, no GitHub release, no
// `git tag`). It exits 0 when everything runnable-in-CI passes and non-zero if
// any real step fails.
//
// NO SECRETS in this file: signing identity / notary secret NAMES are named,
// values never are. This script is on the OSS mirror allowlist and is published
// to the public mirror repo (docs/spec/10 topology), so secret values must never
// live in it.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, readFileSync, writeFileSync, cpSync, symlinkSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const OPS = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(OPS);

// ─── config / constants ──────────────────────────────────────────────────────
const APP_NAME = "Plugsight";
const BUNDLE_ID = "com.plugsight.app";
const MIN_MACOS = "13.0";
const MCP_PKG_NAME = "@plugsight/mcp";
// The Developer ID used at release time. This is a public certificate NAME (the
// identity string), not a secret; the private key lives in the login keychain
// (local) or is imported from APPLE_DEVELOPER_ID_CERT_P12_BASE64 (CI).
const SIGN_IDENTITY = "Developer ID Application: DOMINIC FREI (K4GPUAV422)";
const NOTARY_PROFILE = "plugsight-notary";

const BUILD_DIR = join(ROOT, "build");
const DIST_DIR = join(ROOT, "dist");
const APP_BUNDLE = join(BUILD_DIR, `${APP_NAME}.app`);
const DMG_STAGE = join(BUILD_DIR, "dmg");
const RELEASE_BIN = join(ROOT, ".build", "release");

// ─── cli ─────────────────────────────────────────────────────────────────────
const argv = new Set(process.argv.slice(2));
const DRY = argv.has("--dry-run");
if (argv.has("--help") || argv.has("-h")) {
  console.log("usage: node ops/release.mjs [--dry-run]\n\n" +
    "  --dry-run  run preflight + gates + build for real; print (skip) sign,\n" +
    "             notarize, npm publish, GitHub release, and post-flight.");
  process.exit(0);
}

// ─── logging ─────────────────────────────────────────────────────────────────
let stepNo = 0;
const log = (m = "") => console.log(m);
const step = (title) => log(`\n━━━ Step ${++stepNo}/7: ${title} ${DRY ? "(dry-run)" : ""}`);
const ok = (m) => log(`  ✓ ${m}`);
const warn = (m) => log(`  ⚠ ${m}`);
const skip = (m) => log(`  ⤿ SKIPPED (dry-run): ${m}`);
const would = (cmd) => log(`      would run: ${cmd}`);
function fatal(m) {
  console.error(`\n✗ FATAL: ${m}`);
  process.exit(1);
}

// Run a command with inherited stdio; fatal on non-zero unless {allowFail}.
function run(cmd, args, { cwd = ROOT, allowFail = false, label } = {}) {
  const printable = `${cmd} ${args.join(" ")}`.trim();
  log(`  $ ${printable}`);
  const r = spawnSync(cmd, args, { cwd, stdio: "inherit", encoding: "utf8" });
  if (r.error) {
    if (allowFail) return r;
    fatal(`${label || printable}: ${r.error.message}`);
  }
  if (r.status !== 0 && !allowFail) {
    fatal(`${label || printable} exited ${r.status}`);
  }
  return r;
}

// Run a command capturing stdout (for probes); fatal on failure unless allowFail.
function capture(cmd, args, { cwd = ROOT, allowFail = false } = {}) {
  const r = spawnSync(cmd, args, { cwd, encoding: "utf8" });
  if ((r.error || r.status !== 0) && !allowFail) {
    fatal(`${cmd} ${args.join(" ")} failed: ${r.error?.message || r.stderr || `exit ${r.status}`}`);
  }
  return r;
}

// ─── version helpers ─────────────────────────────────────────────────────────
function readVersionJson() {
  const p = join(OPS, "version.json");
  if (!existsSync(p)) fatal("ops/version.json is missing (the single version source)");
  let parsed;
  try { parsed = JSON.parse(readFileSync(p, "utf8")); }
  catch (e) { fatal(`ops/version.json is not parseable: ${e.message}`); }
  if (typeof parsed.version !== "string" || !parsed.version.trim()) {
    fatal(`ops/version.json has no usable "version" string`);
  }
  return parsed.version.trim();
}

// ═══ Step 1: Preflight ═══════════════════════════════════════════════════════
function preflight() {
  step("Preflight");

  // Clean tree. CI checks out a clean commit; a dirty local tree only WARNs in
  // dry-run so the gate stays runnable from any working state.
  const status = capture("git", ["status", "--porcelain"], { allowFail: true }).stdout || "";
  if (status.trim()) {
    if (DRY) warn("working tree is not clean (fatal in a real release)");
    else fatal("working tree is not clean — commit or stash before releasing");
  } else ok("git tree clean");

  // Branch. Releases are tagged from `main`; dry-run WARNs so CI can run it from
  // any branch (docs/spec/08 item 1).
  const branch = (capture("git", ["rev-parse", "--abbrev-ref", "HEAD"], { allowFail: true }).stdout || "").trim();
  if (branch !== "main") {
    if (DRY) warn(`on branch '${branch}', not 'main' (fatal in a real release)`);
    else fatal(`releases are tagged from 'main'; current branch is '${branch}'`);
  } else ok("on main");

  // Version source.
  const version = readVersionJson();
  ok(`version.json = ${version}`);

  // Changelog entry present for this version.
  const changelogPath = join(ROOT, "CHANGELOG.md");
  if (!existsSync(changelogPath)) fatal("CHANGELOG.md is missing");
  const changelog = readFileSync(changelogPath, "utf8");
  // Accept `## 0.1.0`, `## [0.1.0]`, with optional trailing " — …".
  const esc = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const entryRe = new RegExp(`^##\\s+\\[?${esc}\\]?(\\s|$)`, "m");
  if (!entryRe.test(changelog)) fatal(`CHANGELOG.md has no entry for version ${version} (expected a "## ${version}" heading)`);
  ok(`changelog entry for ${version} present`);

  // Em-dash guard. The changelog section ships verbatim as the GitHub release
  // notes (step 6), so an em dash there violates the house style at the worst
  // possible place. Refuse a real release; a dry-run only warns, matching the
  // clean-tree and branch checks above, so CI stays runnable while a stray em
  // dash is cleaned up. The literal in the test is the character being detected.
  const section = changelogSection(version);
  if (/—/.test(section)) {
    if (DRY) warn(`em dash in the CHANGELOG [${version}] section (fatal in a real release; remove it)`);
    else fatal(`em dash in the CHANGELOG [${version}] section: remove it before releasing (house style)`);
  } else ok(`no em dash in the CHANGELOG [${version}] section`);

  // Version consistency across version.json / mcp package / daemon constant.
  const mcpPkg = JSON.parse(readFileSync(join(ROOT, "mcp", "package.json"), "utf8"));
  if (mcpPkg.version !== version) {
    fatal(`mcp/package.json version ${mcpPkg.version} != version.json ${version} — run 'node ops/sync-versions.mjs'`);
  }
  ok(`mcp/package.json version = ${version}`);

  const mcpServer = readFileSync(join(ROOT, "mcp", "src", "server.ts"), "utf8");
  const sv = mcpServer.match(/export const SERVER_VERSION\s*=\s*"([^"]+)"/);
  if (!sv) fatal(`could not read SERVER_VERSION constant from mcp/src/server.ts`);
  if (sv[1] !== version) {
    fatal(`mcp SERVER_VERSION ${sv[1]} != version.json ${version} — run 'node ops/sync-versions.mjs'`);
  }
  ok(`mcp SERVER_VERSION = ${version}`);

  const daemonMain = readFileSync(join(ROOT, "Sources", "plugsightd", "main.swift"), "utf8");
  const dm = daemonMain.match(/let\s+daemonVersion\s*=\s*"([^"]+)"/);
  if (!dm) fatal(`could not read daemonVersion constant from Sources/plugsightd/main.swift`);
  if (dm[1] !== version) {
    fatal(`plugsightd daemonVersion ${dm[1]} != version.json ${version} — run 'node ops/sync-versions.mjs'`);
  }
  ok(`plugsightd daemonVersion = ${version}`);

  return { version, branch };
}

// ═══ Step 2: Gates ═══════════════════════════════════════════════════════════
function gates() {
  step("Gates");

  // Swift suite.
  run("swift", ["test"], { label: "swift test" });
  ok("swift test");

  // TS/MCP suite. Ensure deps are present (CI-clean checkout has none).
  if (!existsSync(join(ROOT, "mcp", "node_modules"))) {
    run("npm", ["--prefix", "mcp", "ci"], { label: "npm ci (mcp)" });
  }
  run("npm", ["--prefix", "mcp", "test"], { label: "mcp test" });
  ok("mcp test");

  // Seam gate.
  run("./ops/check-seam.sh", [], { label: "seam gate" });
  ok("seam gate");

  // Secret scan — fatal on any finding (non-zero exit). Public-from-day-one repo.
  run("gitleaks", ["detect", "--no-banner", "--source", "."], { label: "gitleaks secret scan" });
  ok("secret scan (gitleaks): no findings");

  // Drift gate.
  run("node", ["ops/check-drift.mjs"], { label: "drift gate" });
  ok("drift gate");
}

// ═══ Step 3: Build ═══════════════════════════════════════════════════════════
function build(version) {
  step("Build");

  // Clean previous artifacts so the bundle is reproducible.
  rmSync(BUILD_DIR, { recursive: true, force: true });
  rmSync(DIST_DIR, { recursive: true, force: true });
  mkdirSync(BUILD_DIR, { recursive: true });
  mkdirSync(DIST_DIR, { recursive: true });

  // Release-config build of the daemon + the app executable. `swift build`
  // honors only the last --product, so build each product in its own pass.
  run("swift", ["build", "-c", "release", "--product", "plugsightd"],
    { label: "swift build -c release --product plugsightd" });
  run("swift", ["build", "-c", "release", "--product", "PlugsightApp"],
    { label: "swift build -c release --product PlugsightApp" });
  ok("release build (plugsightd + PlugsightApp)");

  const appExe = join(RELEASE_BIN, "PlugsightApp");
  const daemonExe = join(RELEASE_BIN, "plugsightd");
  for (const [name, p] of [["PlugsightApp", appExe], ["plugsightd", daemonExe]]) {
    if (!existsSync(p)) fatal(`expected release binary missing: ${name} (${p})`);
  }

  // Assemble Plugsight.app (docs/spec/02 layout).
  //   Contents/MacOS/Plugsight          the app executable
  //   Contents/MacOS/plugsightd         the daemon, shipped inside the app
  //   Contents/Library/SystemExtensions/  ES appex slot (see NOTE below)
  //   Contents/Resources/               SwiftPM resource bundles
  //   Contents/Info.plist
  const contents = join(APP_BUNDLE, "Contents");
  const macos = join(contents, "MacOS");
  const resources = join(contents, "Resources");
  const sysext = join(contents, "Library", "SystemExtensions");
  mkdirSync(macos, { recursive: true });
  mkdirSync(resources, { recursive: true });
  mkdirSync(sysext, { recursive: true });

  cpSync(appExe, join(macos, APP_NAME));
  cpSync(daemonExe, join(macos, "plugsightd"));
  ok("app + daemon copied into Contents/MacOS");

  // SwiftPM resource bundles (e.g. Plugsight_PlugsightCore.bundle carrying the
  // legit-composite allowlist) → Contents/Resources.
  let bundleCount = 0;
  for (const entry of readdirSync(RELEASE_BIN)) {
    if (entry.endsWith(".bundle")) {
      cpSync(join(RELEASE_BIN, entry), join(resources, entry), { recursive: true });
      bundleCount++;
    }
  }
  ok(`resource bundles copied: ${bundleCount}`);

  // App icon from the brand master (the pendpost iconutil recipe): sips scales
  // brand/icons/icon-1024.png to the standard iconset sizes at 1x + @2x, then
  // iconutil compiles AppIcon.icns into Contents/Resources. Guarded so a
  // checkout without the brand master (or a box without iconutil) still builds;
  // cert-free and deterministic.
  const iconSrc = join(ROOT, "brand", "icons", "icon-1024.png");
  const haveIconutil = spawnSync("iconutil", ["--help"], { encoding: "utf8" }).error === undefined;
  if (existsSync(iconSrc) && haveIconutil) {
    const iconset = join(BUILD_DIR, "AppIcon.iconset");
    rmSync(iconset, { recursive: true, force: true });
    mkdirSync(iconset, { recursive: true });
    for (const s of [16, 32, 128, 256, 512]) {
      capture("sips", ["-z", String(s), String(s), iconSrc, "--out", join(iconset, `icon_${s}x${s}.png`)]);
      capture("sips", ["-z", String(s * 2), String(s * 2), iconSrc, "--out", join(iconset, `icon_${s}x${s}@2x.png`)]);
    }
    capture("iconutil", ["-c", "icns", iconset, "-o", join(resources, "AppIcon.icns")]);
    rmSync(iconset, { recursive: true, force: true });
    ok("AppIcon.icns compiled from brand/icons/icon-1024.png");
  } else {
    warn(`no app icon compiled (${existsSync(iconSrc) ? "iconutil unavailable" : "brand/icons/icon-1024.png missing"})`);
  }

  // NOTE on the ES appex: PlugsightESExtension is the thin ES/XPC layer (07 N12).
  // Building it into a *.systemextension appex requires the ES entitlement grant
  // (07 N0) — pending on the Apple account. Per docs/spec/08, the appex is only
  // bundled when the grant exists; otherwise the capability table says so. Here
  // we assemble the SLOT and note it.
  writeFileSync(join(sysext, "README.txt"),
    "ES system extension appex slot.\n" +
    "com.plugsight.esextension.systemextension is placed here ONLY when the\n" +
    "Endpoint Security entitlement grant (docs/spec/07 N0) is present on the\n" +
    "signing account. Until then the app ships without the extension target and\n" +
    "the capability table reports Endpoint Security as unavailable (docs/spec/08).\n");
  warn("ES appex slot assembled + noted (bundled only when the ES entitlement grant exists — docs/spec/08)");

  // Info.plist — version from version.json (the single source).
  const infoPlist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${version}</string>
	<key>CFBundleVersion</key>
	<string>${version}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>MIT-licensed. Plugsight observes and explains; it does not block hardware attacks.</string>
</dict>
</plist>
`;
  writeFileSync(join(contents, "Info.plist"), infoPlist);
  ok(`Info.plist written (id ${BUNDLE_ID}, min macOS ${MIN_MACOS}, version ${version})`);

  // The dmg is assembled later, in step 4, AFTER the app bundle is codesigned,
  // so the shipped dmg carries the SIGNED app. See assembleDmg() and
  // signNotarizeStaple().
  return { appBundle: APP_BUNDLE };
}

// Assemble the dmg from whatever is currently in APP_BUNDLE, with a
// drag-to-install /Applications symlink, via hdiutil (create-dmg is not a
// dependency). Called AFTER signing in the real path, so the dmg carries the
// signed app; under --dry-run the app is unsigned, which matches the dry-run
// contract (steps 1-3 build for real, signing is skipped). Returns the dmg path.
function assembleDmg(version) {
  rmSync(DMG_STAGE, { recursive: true, force: true });
  mkdirSync(DMG_STAGE, { recursive: true });
  cpSync(APP_BUNDLE, join(DMG_STAGE, `${APP_NAME}.app`), { recursive: true });
  try { symlinkSync("/Applications", join(DMG_STAGE, "Applications")); } catch { /* best effort */ }

  const dmgPath = join(DIST_DIR, `${APP_NAME}-${version}.dmg`);
  run("hdiutil", ["create", "-volname", APP_NAME, "-srcfolder", DMG_STAGE,
    "-ov", "-fs", "HFS+", "-format", "UDZO", dmgPath], { label: "hdiutil create" });
  if (!existsSync(dmgPath)) fatal(`dmg was not produced at ${dmgPath}`);
  ok(`dmg assembled from the ${DRY ? "unsigned (dry-run)" : "signed"} app: ${dmgPath.replace(ROOT + "/", "")}`);
  return dmgPath;
}

// ═══ Step 4: Sign + package + notarize + staple ══════════════════════════════
// Correct order, and the reason this function owns dmg assembly: codesign the
// app bundle FIRST (inside-out), then build the dmg FROM the signed bundle, then
// codesign the dmg and notarize + staple it. Building the dmg before signing
// (as an earlier version did in step 3) shipped an unsigned inner app that would
// fail notarization and trip Gatekeeper. Returns the dmg path for later steps.
function signNotarizeStaple({ version, appBundle }) {
  step("Sign + package + notarize + staple");
  const daemon = join(appBundle, "Contents", "MacOS", "plugsightd");
  const appExe = join(appBundle, "Contents", "MacOS", APP_NAME);
  const esAppex = join(appBundle, "Contents", "Library", "SystemExtensions", "com.plugsight.esextension.systemextension");
  const cs = (t) => `codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${t}"`;

  if (DRY) {
    // The real path signs the app BEFORE assembling the dmg. Dry-run prints the
    // signing as "would run", then still assembles the (unsigned) dmg so the
    // build artifact exists, then prints the dmg signing + notarization.
    skip("codesign the daemon, ES extension, then the app bundle (inside-out)");
    would(cs(daemon));
    would(`${cs(esAppex)}   # only present when the ES entitlement grant exists`);
    would(cs(appExe));
    would(`codesign --verify --deep --strict --verbose=2 "${appBundle}"`);
    const dmgPath = assembleDmg(version);
    skip("codesign + notarize + staple the dmg (built from the signed app in a real release)");
    would(`codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${dmgPath}"`);
    would(`ops/notarize.sh "${dmgPath}" --keychain-profile ${NOTARY_PROFILE}`);
    would(`# CI variant: ops/notarize.sh "${dmgPath}" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"`);
    return { dmgPath };
  }

  // Real signing: identity from the login keychain (local) or imported from
  // APPLE_DEVELOPER_ID_CERT_P12_BASE64 / APPLE_DEVELOPER_ID_CERT_PASSWORD (CI).
  // Inside-out: daemon, ES extension, then the app bundle.
  run("codesign", ["--force", "--options", "runtime", "--timestamp", "--sign", SIGN_IDENTITY, daemon],
    { label: "codesign daemon" });
  if (existsSync(esAppex)) {
    run("codesign", ["--force", "--options", "runtime", "--timestamp", "--sign", SIGN_IDENTITY, esAppex],
      { label: "codesign ES extension" });
  } else {
    warn("ES extension appex absent (entitlement grant pending) — skipping its signature");
  }
  run("codesign", ["--force", "--options", "runtime", "--timestamp", "--sign", SIGN_IDENTITY, appExe],
    { label: "codesign app" });
  run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", appBundle], { label: "codesign verify" });
  ok("codesigned daemon + (ES) + app");

  // Build the dmg FROM the now-signed bundle, then codesign the dmg itself.
  const dmgPath = assembleDmg(version);
  run("codesign", ["--force", "--timestamp", "--sign", SIGN_IDENTITY, dmgPath], { label: "codesign dmg" });
  ok("codesigned dmg (built from the signed app)");

  run("./ops/notarize.sh", [dmgPath, "--keychain-profile", NOTARY_PROFILE], { label: "notarize + staple" });
  ok("notarized + stapled dmg");
  return { dmgPath };
}

// ═══ Step 5: npm publish ═════════════════════════════════════════════════════
function npmPublish() {
  step("npm publish");

  // docs/spec/08: refuse to publish an MCP package whose declared apiVersion
  // does not match the daemon it was built against. The daemon speaks
  // apiVersion 1 (Router.HelloResult); the MCP declares the apiVersions it knows
  // in its generated contract. Assert the daemon's version is one the MCP knows.
  const daemonApi = daemonApiVersion();
  const mcpApis = mcpKnownApiVersions();
  if (!mcpApis.includes(daemonApi)) {
    fatal(`apiVersion mismatch: daemon speaks ${daemonApi}, ${MCP_PKG_NAME} knows [${mcpApis.join(", ")}] — refusing to publish`);
  }
  ok(`apiVersion compatible: daemon=${daemonApi} ∈ mcp[${mcpApis.join(", ")}]`);

  if (DRY) {
    skip(`publish ${MCP_PKG_NAME}`);
    would("npm --prefix mcp ci && npm --prefix mcp run build");
    would("npm --prefix mcp publish --provenance --access public");
    return;
  }
  run("npm", ["--prefix", "mcp", "ci"], { label: "npm ci (mcp)" });
  run("npm", ["--prefix", "mcp", "run", "build"], { label: "npm build (mcp)" });
  run("npm", ["--prefix", "mcp", "publish", "--provenance", "--access", "public"], { label: "npm publish" });
  ok(`published ${MCP_PKG_NAME}`);
}

// The daemon's advertised apiVersion, read from the HelloResult construction.
function daemonApiVersion() {
  const router = readFileSync(join(ROOT, "Sources", "PlugsightDaemon", "API", "Router.swift"), "utf8");
  const m = router.match(/HelloResult\(\s*apiVersion:\s*(\d+)/);
  if (!m) fatal("could not read the daemon apiVersion from Router.swift");
  return Number(m[1]);
}

// The apiVersions the MCP package declares it understands, from its generated
// contract (mcp/contract/tools.json, produced by gen:contract from client.ts).
function mcpKnownApiVersions() {
  const contractPath = join(ROOT, "mcp", "contract", "tools.json");
  if (!existsSync(contractPath)) fatal("mcp/contract/tools.json missing — run 'npm --prefix mcp run build'");
  const contract = JSON.parse(readFileSync(contractPath, "utf8"));
  if (!Array.isArray(contract.apiVersions) || contract.apiVersions.length === 0) {
    fatal("mcp/contract/tools.json declares no apiVersions");
  }
  return contract.apiVersions.map(Number);
}

// ═══ Step 6: GitHub release ══════════════════════════════════════════════════
function githubRelease({ version, dmgPath }) {
  step("GitHub release");
  const tag = `v${version}`;
  if (DRY) {
    skip(`tag + create GitHub release ${tag} and upload the dmg`);
    would(`git tag -a ${tag} -m "Plugsight ${version}"   # NOT run in dry-run`);
    would(`git push origin ${tag}`);
    would(`gh release create ${tag} "${dmgPath}" --title "Plugsight ${version}" --notes-file <(changelog section ${version})`);
    return;
  }
  run("git", ["tag", "-a", tag, "-m", `Plugsight ${version}`], { label: "git tag" });
  run("git", ["push", "origin", tag], { label: "git push tag" });
  const notes = changelogSection(version);
  const notesPath = join(BUILD_DIR, `release-notes-${version}.md`);
  writeFileSync(notesPath, notes);
  run("gh", ["release", "create", tag, dmgPath, "--title", `Plugsight ${version}`, "--notes-file", notesPath],
    { label: "gh release create" });
  ok(`GitHub release ${tag} created`);
}

// Extract the changelog body for a version (the lines under its heading up to
// the next `## ` heading), for the GitHub release notes.
function changelogSection(version) {
  const changelog = readFileSync(join(ROOT, "CHANGELOG.md"), "utf8").split("\n");
  const esc = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const headRe = new RegExp(`^##\\s+\\[?${esc}\\]?(\\s|$)`);
  const out = [];
  let inside = false;
  for (const line of changelog) {
    if (headRe.test(line)) { inside = true; continue; }
    if (inside && /^##\s+/.test(line)) break;
    if (inside) out.push(line);
  }
  return out.join("\n").trim() + "\n";
}

// ═══ Step 7: Post-flight ═════════════════════════════════════════════════════
function postFlight({ version }) {
  step("Post-flight");
  if (DRY) {
    skip("verify the PUBLISHED artifacts actually work");
    would(`gh release download v${version} --pattern "${APP_NAME}-*.dmg" --dir /tmp/plugsight-postflight`);
    would(`hdiutil attach /tmp/plugsight-postflight/${APP_NAME}-${version}.dmg`);
    would(`spctl -a -vv -t install "/Volumes/${APP_NAME}/${APP_NAME}.app"   # signature + notarization`);
    would(`cp -R "/Volumes/${APP_NAME}/${APP_NAME}.app" /Applications/ && open /Applications/${APP_NAME}.app`);
    would(`npx ${MCP_PKG_NAME}@latest   # against the installed app`);
    would(`# assert get_status returns monitoring green`);
    return;
  }
  // Real post-flight is inherently interactive/networked; it is orchestrated by
  // the release runner after upload. Left as explicit run() calls would go here.
  warn("post-flight runs against the live published artifacts (see the manual checklist)");
}

// ─── main ────────────────────────────────────────────────────────────────────
function main() {
  log(`Plugsight release pipeline${DRY ? " — DRY RUN" : ""}`);
  log(`repo: ${ROOT}`);

  const { version } = preflight();
  gates();
  const { appBundle } = build(version);
  const { dmgPath } = signNotarizeStaple({ version, appBundle });
  npmPublish();
  githubRelease({ version, dmgPath });
  postFlight({ version });

  log(`\n✓ release pipeline ${DRY ? "DRY RUN complete: steps 1-3 ran, dmg assembled unsigned, 4-7 printed as skipped" : "complete"}`);
  log(`  version: ${version}`);
  log(`  dmg:     ${dmgPath.replace(ROOT + "/", "")}`);
  process.exit(0);
}

main();
