# Changelog

All notable changes to Plugsight are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The single
source of truth for the current version is `ops/version.json`; the release
pipeline (`ops/release.mjs`) refuses to ship when the changelog has no entry for
that version.

Downloadable releases (the signed, notarized `.dmg`) live on the public mirror,
[plugsightlabs/plugsight-public](https://github.com/plugsightlabs/plugsight-public/releases).
The version tag is also pushed to the private workshop repo for provenance.

## [1.1.0] - 2026-09-05

An app-wide UX overhaul. The app now answers "is this device safe" directly
instead of showing raw telemetry. Plugsight stays a local-only detector: it
observes and explains, and it does not block or claim to stop hardware attacks.

### Added

- **Devices home.** The main window opens on your devices, each with a safety
  verdict (safe, needs attention, unsafe, or not checked), the reasons behind
  it, and one recommended action that actually performs what it names.
- **Real macOS notifications.** A single notifications switch plus a separate
  new-device checkbox in Settings; unsafe verdicts and (optionally) new devices
  produce a system banner. If notification permission is denied, Settings says
  so and shows the steps to fix it.
- **Activity view.** Replaces the Timeline tab: history on request, reachable
  from the Devices home, with working filters and humanized day headers.
- Groundwork for holding new drives until they are scanned. It ships inactive in
  this release: Apple has granted the Endpoint Security entitlement, and the hold
  path will be switched on in a later release once it is verified on real
  hardware. Nothing in the app claims the capability before then.

### Changed

- Settings rebuilt: each permission row explains its state in plain words with
  step-by-step guidance that opens the exact System Settings pane, and the
  extension row reports its honest status instead of offering approvals that
  cannot succeed.
- The menu-bar popover sizes itself to its content, never clips, and its
  Details action lands on the right device.

### Fixed

- Scan history is now filtered per device, with dates and failure reasons; one
  device's scans no longer appear under every device.
- Times render in your own locale and time zone everywhere; no more UTC strings
  shown as if they were local.
- Scans interrupted by a daemon restart are reconciled instead of showing as
  running forever, and internal-volume scan rows no longer clutter history.
- The daemon reports its real installed version.

## [1.0.1] - 2026-08-31

A fixes release for the menu-bar popover, the Settings extension row, and
scan-on-mount. Plugsight stays a local-only detector: it observes and explains,
and it does not block or claim to stop hardware attacks.

### Fixed

- Scan-on-mount no longer runs on the Mac's own internal storage. Disk
  Arbitration reports every mounted volume, so the boot volume and Apple's APFS
  system volumes (Preboot, VM, xarts, iSCPreboot, Hardware, Update, Data) were
  each scanned and, being unreadable, reported "Scan of ... failed (engine
  error)". Only drives you plug in are watched now; internal and network volumes
  are skipped, so that wall of errors is gone.
- The menu-bar popover no longer clips its top. With a busy list the content
  could be sized taller than the popover and get centre-clipped, hiding the
  "Plugsight" title and the Open Plugsight button off the top of the box.

### Changed

- The Settings "Deeper device monitoring" row now reflects its real state.
  Instead of one generic "needs attention" look for every not-on case, it reads
  as On, Waiting for your approval, or Not set up, each with its own icon and a
  one-line next step. Its button opens the system approval prompt directly, so
  the extension is no longer a dead end that drops you on a pane with nothing
  highlighted.

## [1.0.0] - 2026-08-29

The first stable release. Since 0.1.0 the new-user setup and recovery paths were
audited end to end and wired, so every onboarding and settings action reaches its
destination. Plugsight stays a local-only detector: it observes and explains, and
it does not block, prevent, or claim to stop hardware attacks.

### Fixed

- Onboarding permission steps now deep-link to the correct System Settings panes,
  so a first-time setup no longer dead-ends on a step with nowhere to go.
- The main window is reachable from the popover, and the popover recovery actions
  perform their action instead of doing nothing.
- Settings recovery actions (restart monitoring, re-grant a permission) now carry
  out the action they name.

### Changed

- Onboarding step copy is single-sourced, so the app and the docs describe each
  step in the same words.
- Timeline snapshot fixtures run on a pinned clock, so the day-header tests are
  reproducible run to run.

### Notes

- The downloadable, signed and notarized dmg lives on the public mirror. The MCP
  server ships as `@plugsight/mcp` on the same `apiVersion` 1 as the daemon.

## [0.1.0] - 2026-08-29

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

### Manual checks (hardware/human, outside CI)

These require real hardware or a human and are validated out of band, not in CI:

- Real-hardware USB attach/detach probe.
- EICAR vs. real ClamAV end-to-end.
- SIP-relaxed ES activation + live `AUTH_MOUNT` hold/release.
- Accessibility Inspector audit + final canon review of the app snapshots.
- One real signed + notarized dmg opened on a second machine.
