# Plugsight

**See what your USB devices are actually doing.** Plugsight is a macOS-native,
agent-first monitor that watches every device you plug in, scores the ones that
behave like an attack, scans mounted storage, and writes it all into one
plain-language timeline you can read.

It is a **detector, not a blocker**, and it says so on purpose. Plugsight will
never claim to do what host software physically cannot:

- It does **not** block a rogue keyboard before it types. On macOS only the
  built-in accessory prompt can do that; no third-party app can veto a HID
  device. Plugsight alerts, it does not intercept.
- It does **not** detect a dormant malicious cable. An idle implant emits nothing
  a host can see. Only RF hardware finds that. Plugsight never pretends otherwise.
- It does **not** promise deterministic BadUSB catching. Behavioral scoring is
  probabilistic and evadable. Plugsight scores and explains, it does not guarantee.

What Plugsight gives you that nothing else does: **legibility.** The moment a
cable does something, you can read what it did.

## Agent-first

Plugsight is MCP-native. A core daemon owns all monitoring and exposes one local
API. The human menu-bar UI and the Plugsight MCP server are peer clients of that
same API, so every capability is operatable by an agent and by a person.

## Capabilities

Every capability is a tool on the local API, operatable by an agent and by a
person. This table is the exact, complete set of tools the daemon registers:
the capability drift gate (`ops/check-drift.mjs`) fails the build if it drifts
from `mcp/contract/tools.json` by even one row.

<!-- BEGIN:capability-tools (drift-gate-checked against mcp/contract/tools.json — do not edit by hand) -->

| Tool | Writes? | What it does |
|---|---|---|
| `get_status` | no | The daemon health picture: monitoring state, permissions, scanner, and counts. |
| `list_devices` | no | List present and historical devices with a summary, trust tier, and score. |
| `get_device` | no | The full record for one device: interfaces, trust history, score breakdown, counts. |
| `get_timeline` | no | Events newest first, each with a one-sentence plain-language summary. |
| `explain_event` | no | One event with its full explanation: detail payload, why, context, and next actions. |
| `tail_events` | no | Long-poll for live events. |
| `score_device` | no | The current behavioral score with its full per-signal reasoning. |
| `list_alerts` | no | Alerts with their triggering events, current state, why, and suggested actions. |
| `get_scan` | no | A scan's state, progress, per-file verdicts, and quarantine records. |
| `get_policy` | no | The full policy object (scan-on-mount, quarantine, hold, thresholds, retention). |
| `acknowledge_alert` | yes | Move an active alert to acknowledged. |
| `trust_device` | yes | Mark a device trusted. |
| `mute_device` | yes | Mute a device. |
| `flag_device` | yes | Flag a device to watch closely. |
| `clear_device_mark` | yes | Clear a device's trust mark, back to default handling. |
| `scan_storage` | yes | Start a malware scan of a device's volume or a volume path. |
| `cancel_scan` | yes | Cancel a running scan. |
| `restore_quarantine` | yes | Move a quarantined file back to its original location. |
| `set_policy` | yes | Update policy with a partial object; unknown keys are rejected. |

<!-- END:capability-tools -->

Everything Plugsight observes lands in the timeline as one of a fixed,
closed set of event kinds. The daemon prints this same set with
`plugsightd --print-catalog`, and the drift gate fails if this list and that
output disagree.

<!-- BEGIN:capability-event-kinds (drift-gate-checked against `plugsightd --print-catalog` — do not edit by hand) -->

- `device.attached`
- `device.detached`
- `device.interfaces_changed`
- `mismatch.detected`
- `mismatch.allowlisted`
- `hid.typing_burst`
- `score.changed`
- `alert.raised`
- `alert.acknowledged`
- `alert.resolved`
- `trust.changed`
- `volume.mounted`
- `volume.unmounted`
- `volume.held`
- `volume.released`
- `scan.started`
- `scan.finished`
- `scan.skipped`
- `quarantine.restored`
- `esext.iokit_open`
- `daemon.started`
- `daemon.stopped`
- `monitoring.gap`

<!-- END:capability-event-kinds -->

The behavioral score is probabilistic and a patient attacker can evade it;
Plugsight scores and explains, it does not block, prevent, or guarantee.

## Getting started

Plugsight is pre-release. A signed, notarized `.dmg` you can drag to your
Applications folder ships with v1.0; until then you run it from source. You need
macOS 13 or newer and a recent Swift toolchain (the Xcode command-line tools).
Node.js 18 or newer is needed only for the MCP server.

The daemon owns all monitoring; the menu-bar app and the MCP server are peer
clients of it. The one-command path builds both, starts the daemon, waits for
its socket, and launches the app against the same state directory:

```sh
git clone https://github.com/plugsightlabs/plugsight-public.git
cd plugsight-public
ops/dev-run.sh              # daemon + menu-bar app, one command (Ctrl-C stops both)
```

Plugsight is a menu-bar app: look for the shield glyph at the top-right of your
screen. There is no window and no Dock icon. The shield is hollow until the
daemon's first heartbeat, then fills. `ops/dev-run.sh --seed` boots against a
seeded demo database, so you can explore the UI with no hardware plugged in.

To run the pieces by hand instead, start the daemon first, then the app in a
second terminal (if you relocate the state directory with
`PLUGSIGHT_STATE_DIR`, set it identically for both, or the app will look for a
socket the daemon never opened):

```sh
swift run plugsightd        # the daemon: owns all monitoring
swift run PlugsightApp      # second terminal: the menu-bar shield appears
```

Basic monitoring (device attach and detach, HID behavior, volume mounts, and
ClamAV storage scans if ClamAV is installed via Homebrew) works from source with
no special privileges. The Endpoint Security layer that adds per-process device
opens and the opt-in mount hold needs the notarized build and an Apple-granted
entitlement, and lands with v1.0.

To drive the same daemon as an agent, point an MCP client at the server. From a
published release that is `npx @plugsight/mcp`; from this checkout, build and run
it directly:

```sh
cd mcp && npm ci && npm run build && node dist/index.js
```

Call `get_status` first. The full specification lives in
[`docs/spec/`](docs/spec/).

## Local pre-push gate

The one gate (`ops/gate.sh`: `swift build`, `swift test`, `ops/check-seam.sh`, the
MCP build and tests, `ops/check-drift.mjs`, about two minutes) also runs locally as
a git pre-push hook, so a red build cannot land on an integration branch. Enable it
once per clone (no root package.json, so run the script directly):

```sh
node ops/install-hooks.mjs
```

That sets `core.hooksPath` to `.githooks` (stored in the shared `.git/config`, so it
covers every worktree at once). The hook runs the gate ONLY when you push to
`develop`, `staging`, or `main`; `claude/*`, `fix/*`, and `feature/*` pushes stay
instant. Bypass a genuine non-code push with `git push --no-verify`, or set
`PLUGSIGHT_SKIP_PREPUSH=1` (used by the kaizen orchestrator once it has already run
the gate itself).

## License

MIT. See [`LICENSE`](LICENSE).
