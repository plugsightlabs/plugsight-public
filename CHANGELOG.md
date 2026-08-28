# Changelog

All notable changes to Plugsight are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The single
source of truth for the current version is `ops/version.json`; the release
pipeline (`ops/release.mjs`) refuses to ship when the changelog has no entry for
that version.

## [0.1.0] - Unreleased

First tagged build of Plugsight: a local-only macOS menu-bar app plus MCP server
that watches what plugs into your Mac and tells you, honestly, what it can and
cannot see. It observes and explains; it does not block, prevent, or claim to
stop hardware attacks.

### Added

- **Menu-bar app (`Plugsight.app`)**. Nine surfaces (seven SwiftUI: menu-bar
  glyph, popover, event timeline, live device list, device inspector, onboarding,
  and settings; plus a macOS notification and the MCP face). View models are
  CI-testable independently of a live socket.
- **Daemon (`plugsightd`)**: local JSON-RPC-over-UDS API (`apiVersion` 1) behind
  a per-boot auth token, event fan-out, and a closed `EventKindCatalog` of 23
  event kinds surfaced via `--print-catalog`.
- **Device collection**: IOKit / HID-timing / DiskArbitration sources composed
  behind the frozen `CollectorEvent` seam; `PlugsightCore` stays platform-neutral
  (guarded by `ops/check-seam.sh`).
- **Detection**: mismatch rules, a behavioral HID-timing score with an explicit
  score-payload caveat, a shipped legit-composite allowlist, and trust tiers.
- **ClamAV integration**. Optional on-device scanning: engine discovery, scan
  orchestration, quarantine + restore, and definitions-age reporting. ClamAV is
  installed by the user (Homebrew), guided from Settings.
- **Endpoint Security extension**: a ruthlessly thin ES/XPC layer over a pure,
  CI-testable decision core (mount-hold, fail-open, XPC peer validation). Bundled
  only when the ES entitlement grant is present; the capability table says so
  when it is not.
- **MCP server (`@plugsight/mcp`)**: 19 tools as a thin stdio-MCP adapter over
  the daemon API, with a generated contract (`mcp/contract/tools.json`) and a
  round-trip test against a live seeded daemon.
- **Honesty drift gate**: `ops/check-drift.mjs` fails CI if the README / docs
  claim more or fewer tools or event kinds than the software registers, or if a
  banned marketing claim appears outside a quoted negation.
- **Ship pipeline**. `ops/release.mjs`: one command, seven fatal-on-failure
  steps (preflight, gates, build, sign+notarize+staple, npm publish, GitHub
  release, post-flight), with a `--dry-run` mode that runs preflight, gates, and
  the build for real and prints the release-time steps it would run.

### Known manual gates (owner evidence pending before tagging)

- Real-hardware USB attach/detach probe.
- EICAR vs. real ClamAV end-to-end.
- SIP-relaxed ES activation + live `AUTH_MOUNT` hold/release.
- Accessibility Inspector audit + final canon review of the app snapshots.
- One real signed + notarized dmg opened on a second machine.
