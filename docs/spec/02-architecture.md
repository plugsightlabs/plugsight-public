# 02. Architecture

Four processes, one brain, one API. This doc specifies each component, the local API in full, the
trust boundaries, and the signing story. Platform limits cited as L1..L10 come from 01.

```
                       +--------------------------------------+
                       |  plugsightd (Swift, LaunchAgent)     |
                       |                                      |
  IOKit / IOHIDManager |  +-----------+   +---------------+   |
  attach/detach ------->  | Collector |   | HID scorer    | <---- CGEventTap (Input Monitoring)
                       |  +-----------+   +---------------+   |
  ES events via XPC    |  +-----------+   +---------------+   |
  <-------------------->  | ES bridge |   | ClamAV orch.  | ----> clamscan / clamd
                       |  +-----------+   +---------------+   |
                       |  +-----------+   +---------------+   |
                       |  | Analyzer  |   | Event store   | ----> SQLite
                       |  | (rules)   |   | + policy      |   |
                       |  +-----------+   +---------------+   |
                       |            Local API (JSON-RPC       |
                       |            over Unix socket)         |
                       +-------------------|------------------+
                            |              |               |
                 +----------+---+  +-------+-------+  +----+-----------+
                 | Menu-bar app |  | MCP server    |  | any local tool |
                 | (SwiftUI)    |  | (TS, via npx) |  | with the token |
                 +--------------+  +---------------+  +----------------+

                 +------------------------------------------+
                 | Plugsight ES extension (system extension)|
                 | root, ES entitlement, XPC to the daemon  |
                 +------------------------------------------+
```

## Components

### plugsightd, the core daemon

Swift, built with SwiftPM, no app bundle of its own (it ships inside the app bundle and is
registered as a per-user LaunchAgent via `SMAppService.agent`). It owns everything stateful:

- **Collector** (IOKit): `IOServiceAddMatchingNotification` for first-match and terminated on USB
  devices, plus `IOHIDManager` device matching for the HID view. On attach it walks the device's
  interfaces and records class/subclass/protocol per interface, descriptor strings, VID/PID/serial,
  and topology (which port, behind which hub). Notify-only (L1).
- **HID scorer**: a listen-only `CGEventTap` on keyboard events (L4). It computes the behavioral
  signals from 05 and attributes keystroke bursts to a device epoch (the window following an
  attach). It stores aggregates and score inputs, never keystroke contents. See "What the scorer
  stores" below; this is a privacy load-bearing wall.
- **Analyzer**: pure functions from collector facts and scorer aggregates to scores and alerts,
  applying the class-mismatch rules and the scoring math from 05, filtered through trust state.
- **ClamAV orchestrator**: watches mount events (DiskArbitration in the base build; richer data
  when the ES extension is active), maps volumes to devices, runs `clamdscan` when a clamd socket
  is available and `clamscan` otherwise, parses results, moves infected files to a quarantine
  directory when policy says so, and writes a scan record plus timeline events.
- **Event store**: SQLite via GRDB, schema in 06. Single writer (the daemon); all clients read
  through the API, never the file.
- **Policy and trust state**: also SQLite, same database, same API.
- **Local API server**: the only way in. Specified below.

The daemon is fully functional without the ES extension (L5 makes this mandatory): collector,
scorer, mismatch rules, and ClamAV all run on IOKit, CGEventTap, and DiskArbitration alone. The
extension upgrades fidelity; it is never a prerequisite.

**What the scorer stores.** Timing metadata only: event timestamps, inter-keystroke deltas,
aggregate statistics, and flags like "typed within N ms of enumeration". Never key codes, never
characters, never the content of what was typed. The one nuance: an alert may record that a burst
contained modifier-heavy chords typical of terminal invocation, as a boolean class, not as keys.
This rule is enforced at the type level (the scorer's event struct has no field for the key code)
and stated in the privacy section of the README.

### The Endpoint Security system extension

A separate binary, bundled at `Plugsight.app/Contents/Library/SystemExtensions/`, activated with
`OSSystemExtensionRequest` from the app, approved by the user in System Settings (L6). It holds the
`com.apple.developer.endpoint-security.client` entitlement (L5) and subscribes to:

- `ES_EVENT_TYPE_NOTIFY_IOKIT_OPEN`: which process opened which device class. This is the "what
  did it then do" half for storage and vendor devices.
- `ES_EVENT_TYPE_NOTIFY_MOUNT` and `NOTIFY_UNMOUNT`: ground truth for volume lifecycle.
- `ES_EVENT_TYPE_AUTH_MOUNT`: the one genuine authorization point we use. Policy option "hold new
  volumes until scanned" answers DENY on mount of a volume from an untrusted device, triggers the
  scan, and the daemon remounts via DiskArbitration after a clean result. Default is off; the UX
  for it is in 04.

It does not and cannot gate HID (L2). The extension is a sensor with one narrow enforcement point,
and the code review bar for it is the highest in the project: every AUTH handler must respond
within the ES deadline (respond fast, decide with cached policy only, never block on the daemon).
If policy state is unavailable the handler answers ALLOW and logs; fail-open is a deliberate
choice, because a security monitor that can brick mounting on its own crash loses the user forever.

Daemon link: the extension publishes an XPC Mach service (name fixed in its Info.plist). The daemon
connects; both sides validate the peer's code-signing requirement (team ID plus bundle ID prefix)
before exchanging anything. Events flow extension to daemon as compact structs; cached policy flows
daemon to extension (a small table: device identity to trust tier, plus the hold-mounts flag).

### The MCP server

TypeScript, `@modelcontextprotocol/sdk`, published as `@plugsight/mcp`, runs with
`npx @plugsight/mcp`. It is deliberately thin: stdio MCP on one side, the local socket on the
other, a pure adapter with no state beyond its socket connection and no business logic. Tool
contract in 03. It reads the socket path and token from the well-known location (below) so setup
is zero-config on a machine where the app runs.

### The menu-bar app

SwiftUI. Status item with a glyph reflecting daemon state and highest active alert severity; a
popover for the last events and active alerts; a timeline window; a device detail surface; a
settings surface. All content via the local API, exactly like the MCP server (peer clients, same
capabilities). The app additionally owns three jobs no other component can do: registering the
LaunchAgent (SMAppService), driving system extension activation, and walking the user through TCC
grants. UX in 04.

## The local API

One interface, JSON-RPC 2.0 over a Unix domain socket. Chosen over loopback HTTP because: no port
to squat or scan, filesystem permissions do the first authorization layer, and framing is trivial
in both Swift and Node without an HTTP dependency in the daemon.

- Socket: `~/Library/Application Support/Plugsight/plugsightd.sock`, mode 0600.
- Framing: newline-delimited JSON, UTF-8, one JSON-RPC message per line.
- Auth: `~/Library/Application Support/Plugsight/api-token` (0600) holds a 32-byte random token,
  regenerated when the daemon first creates its state directory. The first message on every
  connection must be `auth.hello` with the token; anything else gets error `-32001 unauthorized`
  and the connection closes. Socket mode already limits access to the user; the token additionally
  shuts out sandboxed same-user processes that cannot read the state directory, and makes the
  authorization step explicit and loggable.
- Versioning: `auth.hello` returns `{ apiVersion, daemonVersion, capabilities }`. `apiVersion`
  is an integer, bumped only on breaking change. The MCP server refuses to start against an
  `apiVersion` it does not know.

### Methods

Names are `area.verb`. Every mutation records an `actor` (from `auth.hello` clientInfo: `ui`,
`mcp:<agent name>`, `cli`) into the events it generates; the timeline shows who did what.

| Method | Params | Returns | Notes |
|---|---|---|---|
| `auth.hello` | `token`, `clientInfo{name,kind}` | `apiVersion`, `daemonVersion`, `capabilities` | Must be first. `capabilities` reports degraded modes (no Input Monitoring, no ES, no ClamAV). |
| `status.get` | none | daemon state, uptime, permission states, ES state, scanner state, counts | The health surface for both faces. |
| `devices.list` | `filter{present?, trust?, class?}`, `limit`, `cursor` | device summaries | Present and historical devices. |
| `devices.get` | `deviceId` | full device record: interfaces, topology, trust, score, event count, first/last seen | |
| `timeline.list` | `filter{deviceId?, kinds?, severity?, since?, until?}`, `limit`, `cursor` | event list, newest first | THE timeline. Each event carries its one-sentence summary. |
| `events.get` | `eventId` | full event with detail payload and explanation | Explanation format in 06. |
| `events.tail` | `filter` (same as timeline) | subscription id; events then arrive as JSON-RPC notifications `event.appended` on this connection | Cancel with `events.untail`. |
| `score.get` | `deviceId` | score 0-100, confidence, per-signal breakdown, evaluatedAt | Recompute-on-read if inputs changed. |
| `alerts.list` | `filter{state?, severity?, deviceId?}`, `limit`, `cursor` | alerts | States: `active`, `acknowledged`, `resolved`. |
| `alerts.ack` | `alertId`, `comment?` | updated alert | Writes a timeline event with actor. |
| `trust.set` | `deviceId`, `tier` (`trusted`/`muted`/`flagged`/`none`), `note?` | updated device | Tier semantics in 04/05. Emits event; ES policy cache refreshed. |
| `scan.start` | `deviceId` or `volumePath` | `scanId` | Errors if scanner unavailable; error names the fix. |
| `scan.get` | `scanId` | state, progress, verdicts, quarantine paths | |
| `scan.cancel` | `scanId` | updated scan (`canceled`) | Error `conflict` if already terminal. |
| `scans.list` | `filter{deviceId?}`, `limit`, `cursor` | scan summaries | |
| `policy.get` | none | full policy object | |
| `policy.set` | partial policy object | full updated policy | Shallow-merge per top-level key; unknown keys rejected. Owner-gated keys (mount-hold) require `confirm:true`. |

Errors are JSON-RPC error objects with `code`, `message` (human, plain language, states the
recovering action), and `data.kind` (stable machine string: `unauthorized`, `not_found`,
`scanner_unavailable`, `permission_missing`, `es_inactive`, `invalid_params`, `conflict`). 03 maps
these into MCP results verbatim: the agent reads the same honest errors the human does.

## Data flow, end to end

The canonical T1 story, as data: device attach fires the IOKit first-match callback; the collector
reads descriptors and interfaces, upserts the device row, appends `device.attached`; the analyzer
runs mismatch rules, and a hidden-HID hit appends an `alert.raised` with severity from trust state.
The scorer opens a device epoch; keystrokes arrive on the tap 400 ms later; latency and cadence
signals cross their thresholds and the score jumps, appending `score.changed` and escalating the
alert. Every append fans out over `event.appended` to subscribed connections: the menu-bar glyph
turns red and posts a notification; a tailing agent gets the same facts in the same shape. The user
(or the agent, via `trust.set`) decides. Total new concepts a client needs: device, event, alert,
score, trust. Five nouns, both faces, same words (canon: one design language).

## Storage

Single SQLite database, `~/Library/Application Support/Plugsight/plugsight.db`, WAL mode, GRDB,
migrations shipped with the daemon and run at startup. Schema in 06. Quarantine directory
`~/Library/Application Support/Plugsight/quarantine/` (0700), files renamed to their SHA-256 with
an accompanying JSON sidecar (original path, device, scan id, signature name).

## Security model

Trust boundaries, from most to least privileged:

1. **ES extension** (root, ES entitlement). Attack surface: its XPC listener. Mitigation: code-sign
   requirement validation on every connection, no dynamic code paths, AUTH decisions from a local
   cache only.
2. **Daemon** (user). It is the trust boundary for all state. Attack surface: the socket.
   Mitigations: 0600 socket and token as above, JSON decoding with strict schemas, prepared
   statements everywhere (the store never interpolates), path canonicalization before any file
   operation, quarantine moves never follow symlinks.
3. **Clients** (UI, MCP, tools). Untrusted by the daemon beyond the token; every request is
   validated as if hostile.

Rules with no exceptions: no secrets in logs (the token never appears in any log line, nor do
descriptor strings in system log at default level, since product strings can contain junk);
keystroke contents are never stored (scorer section above); everything stays on the machine
(charter item 5). The MCP server inherits all of this by owning nothing.

## Entitlements, signing, notarization

| Artifact | Signed as | Entitlements | Notes |
|---|---|---|---|
| Plugsight.app | Developer ID Application | none beyond defaults; hardened runtime | Hosts daemon binary and extension. Notarized, stapled. |
| plugsightd | inherits app signing | hardened runtime | TCC (Input Monitoring) attributes prompts to the responsible app; verify attribution early in the build, it is a known rough edge with launchd agents. |
| ES extension | Developer ID, distinct bundle id `com.plugsight.esext` | `com.apple.developer.endpoint-security.client` | Needs the Apple entitlement grant (L5). Until granted, dev-only via SIP-relaxed test machine. |
| MCP server | npm package | n/a | Signing story is npm provenance (08). |

Distribution flow in 08. The ES entitlement application is the longest external dependency in the
whole project and is flagged in 07 as a start-immediately node.

## The cross-platform seam

The seam is one protocol boundary: everything above it is portable Swift (analyzer, store, API,
policy, scoring math); everything below it is platform code.

```swift
protocol DeviceEventSource {
    var events: AsyncStream<CollectorEvent> { get }   // attached, detached, interfacesRead,
    func start() throws                               // volumeMounted, volumeUnmounted,
    func stop()                                       // inputActivity (timing metadata only)
}
```

`CollectorEvent` is defined in platform-neutral terms (06's vocabulary: classes as USB standard
codes, no IOKit types, paths as strings). macOS ships `IOKitDeviceSource`, `HIDTimingSource`,
`ESEventSource`. A later Linux collector would implement the same protocol over
udev/hidraw/fanotify; Windows over device notifications and Raw Input. Neither is specified now.
The seam is kept honest by a build target: the analyzer and store compile in a target with no
import of IOKit or CoreGraphics, and CI fails if that target grows such an import (07 wires this
gate).
