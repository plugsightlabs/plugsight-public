# 03. The MCP interface

The MCP server is the agent-facing peer of the menu-bar app. This doc is the complete tool
contract. The parity rule it exists to satisfy: every capability a human has in the UI exists here,
and both faces call the same local API methods (02), so neither can drift ahead of the other. The
drift gate in 08 regenerates the public capability list from this server's registered tools.

## Server behavior

- Package `@plugsight/mcp`, stdio transport, started with `npx @plugsight/mcp`.
- On startup it reads the socket path and token from
  `~/Library/Application Support/Plugsight/` and performs `auth.hello` with
  `clientInfo:{name:<from MCP client>, kind:"mcp"}`. Every mutation an agent makes is therefore
  attributed in the timeline ("muted by agent claude-code"), which the human sees.
- If the daemon is unreachable, tools do not fail opaquely: every call returns a structured error
  `kind:"daemon_unreachable"` with the literal fix ("Start Plugsight from /Applications, or run
  its Start monitoring command"). Same for a stale `apiVersion`.
- Results: each tool returns a JSON object (as structured content) plus a short plain-text
  rendering of the same facts, so both tool-parsing and text-reading agents work. The JSON shapes
  below are the contract; text renderings restate them and add nothing.
- Errors: tool-level errors carry the daemon's human-readable `message` untouched plus the stable
  `kind` from 02. The agent reads the same honest error the human would.

## Tool inventory

| Tool | Maps to | Mutating |
|---|---|---|
| `get_status` | `status.get` | no |
| `list_devices` | `devices.list` | no |
| `get_device` | `devices.get` | no |
| `get_timeline` | `timeline.list` | no |
| `explain_event` | `events.get` | no |
| `tail_events` | `events.tail` (long-poll form) | no |
| `score_device` | `score.get` | no |
| `list_alerts` | `alerts.list` | no |
| `acknowledge_alert` | `alerts.ack` | yes |
| `trust_device` | `trust.set` tier `trusted` | yes |
| `mute_device` | `trust.set` tier `muted` | yes |
| `flag_device` | `trust.set` tier `flagged` | yes |
| `clear_device_mark` | `trust.set` tier `none` | yes |
| `scan_storage` | `scan.start` | yes |
| `cancel_scan` | `scan.cancel` | yes |
| `get_scan` | `scan.get` / `scans.list` | no |
| `restore_quarantine` | `quarantine.restore` | yes |
| `get_policy` | `policy.get` | no |
| `set_policy` | `policy.set` | yes |

Nineteen tools. Anything not in this table is not a capability, and the README may not claim it.
`restore_quarantine` gives agents full parity with the human on un-quarantining (owner ruling, 10),
so it carries the same explicit-risk copy the GUI restore does. One GUI action deliberately has no
tool, with the rationale in 04's parity table: Eject (a standard OS operation, not a Plugsight
capability).

## Read tools

### get_status

No input. Returns the health picture an agent needs before trusting any other answer:

```json
{
  "monitoring": "active" | "degraded" | "stopped",
  "daemonVersion": "1.0.0",
  "permissions": { "inputMonitoring": true, "esExtension": "active" | "inactive" | "not_installed" },
  "scanner": { "available": true, "engine": "clamdscan", "definitionsAgeDays": 2 },
  "devicesPresent": 4,
  "activeAlerts": 1,
  "monitoringGaps": [{ "from": "...", "to": "..." }]
}
```

`degraded` means monitoring runs but a permission is missing; the object states which, and the text
rendering says what is off as a result ("Input Monitoring not granted: typing-behavior scoring is
off; enumeration and mismatch detection still run"). Honesty charter item 1 applied to status.

### list_devices

Input: `{ present?: bool, trust?: "trusted"|"muted"|"flagged"|"none", class?: string,
limit?: int, cursor?: string }`. Returns device summaries:

```json
{ "devices": [{
    "deviceId": "dev_9f3ac2",
    "name": "Logitech USB Receiver",
    "present": true,
    "firstSeen": "...", "lastSeen": "...",
    "vidPid": "046d:c52b", "serial": "...or null",
    "interfaceClasses": ["hid_keyboard", "hid_mouse"],
    "trust": "trusted",
    "score": { "value": 4, "confidence": "high" },
    "activeAlerts": 0
  }], "nextCursor": null }
```

### get_device

Input: `{ deviceId }`. Returns the full record: everything above plus per-interface rows
(class/subclass/protocol, both raw codes and the plain-language role from 06), topology (port and
hub path), trust history with actors, score breakdown, counts of events and scans. Error
`not_found` if the id is unknown.

### get_timeline

Input: `{ deviceId?, kinds?: string[], severity?: "info"|"notice"|"warning"|"critical",
since?, until?, limit?: int (default 50, max 500), cursor? }`. Returns events newest first, each in
the timeline shape from 06:

```json
{ "events": [{
    "eventId": "evt_01H...",
    "at": "2026-08-25T09:14:02.113Z",
    "kind": "hid.typing_burst",
    "severity": "warning",
    "deviceId": "dev_2ab919",
    "summary": "Started typing 0.4 seconds after it was plugged in. Human typists need a few seconds.",
    "actor": "system"
  }], "nextCursor": "..." }
```

`summary` is the legibility payload: one or two plain sentences, already written for a
non-specialist, identical to what the UI shows.

### explain_event

Input: `{ eventId }`. Returns the event plus its full explanation object: the detail payload,
`why` (what rule or signal produced it, with the numbers), `context` (device, trust state at the
time, related events), and `suggestedActions` (each naming the tool that performs it, e.g.
"flag_device"). This is the no-dead-ends rule as API: every explanation names a next action.

### tail_events

MCP is request/response, so tailing is a long poll, stated plainly rather than simulated. Input:
`{ filter?: same as get_timeline, afterCursor?: string, waitSeconds?: int (default 25, max 55) }`.
Behavior: the tool subscribes, then holds the call up to `waitSeconds`, returning as soon as a
matching event arrives, else an empty list and a fresh cursor. This is live-only and best-effort:
it reports the NEXT event that occurs after the call registers its subscription and does NOT replay
historical events that happened before then. `afterCursor` is echoed back as `nextCursor` so an
agent can chain successive live polls; it is not used to fetch past events, because the daemon's
`events.tail` (see `EventsTailParams`) carries no cursor field. An agent loops on this to watch
live. The tool description tells the agent exactly that loop. (Historical replay from a cursor is a
possible future capability; it is not current behavior and would require a daemon-side change.)

### score_device

Input: `{ deviceId }`. Returns the current behavioral score with its full reasoning:

```json
{ "score": 78, "confidence": "medium",
  "signals": [
    { "id": "plug_to_type_latency", "observed": "410ms", "verdict": "suspicious", "weight": 0.35 },
    { "id": "inter_key_timing", "observed": "mean 21ms, stddev 3ms", "verdict": "suspicious", "weight": 0.35 },
    { "id": "redundant_keyboard", "observed": "second keyboard, built-in present", "verdict": "suspicious", "weight": 0.15 },
    { "id": "class_mismatch", "observed": "none", "verdict": "clear", "weight": 0.15 }
  ],
  "explanation": "...plain-language paragraph...",
  "caveat": "Behavioral scoring is probabilistic and a patient attacker can evade it." }
```

The `caveat` field is not decorative; the charter requires it on every score payload, and the
drift gate greps for it.

### list_alerts

Input: `{ state?: "active"|"acknowledged"|"resolved", severity?, deviceId?, limit?, cursor? }`.
Returns alerts, each with its triggering events, current state, and the same
summary/why/suggestedActions shape as explain_event.

### get_scan / get_policy

`get_scan` input: `{ scanId }` or `{ deviceId }` (latest scans for the device). Returns state,
progress, per-file verdicts, quarantine records. `get_policy` returns the full policy object from
06 (scan-on-mount, mount-hold, alert thresholds, notification settings).

## Write tools

All write tools return the updated object plus the timeline event they appended, so the agent can
quote exactly what changed. All are attributed (server behavior above).

### trust_device / mute_device / flag_device / clear_device_mark

Input: `{ deviceId, note?: string }`. Tier semantics (shared with the UI, defined once in 05):

- `trusted`: known device; informational events still recorded, routine alerts suppressed,
  behavioral scoring still runs and a critical score still alerts (trust raises the bar, it does
  not close the file).
- `muted`: stop notifying about this device; everything still recorded.
- `flagged`: watch closely; all severities notify, and the device leads worklists.
- `none` (clear_device_mark): back to default handling.

The response to `trust_device` always includes the forgeability caveat sentence (charter item 4).
Error `not_found` for unknown ids; trusting an absent (historical) device is allowed and said to
apply on next attach.

### acknowledge_alert

Input: `{ alertId, comment?: string }`. Moves an active alert to acknowledged, appends the event,
returns both. Error `conflict` if already resolved.

### scan_storage

Input: `{ deviceId }` or `{ volumePath }`. Starts a scan, returns `{ scanId, state:"running" }`
immediately; the agent polls `get_scan` or watches `tail_events`. Errors: `scanner_unavailable`
(message includes the install fix), `not_found`, `conflict` if the same volume is mid-scan
(returns the running scanId in `data`).

### cancel_scan

Input: `{ scanId }`. Cancels a running scan; the record ends as `canceled`, never `clean`.
Error `conflict` if the scan already reached a terminal state (the current state rides in
`data`). Mirrors the human Cancel control in the device inspector.

### restore_quarantine

Input: `{ quarantineId, confirm: true }`. Moves a quarantined file back to its original location,
appends the timeline event, returns the updated scan/quarantine record. `confirm:true` is mandatory
in the same call because restoring attacker-adjacent bytes is a deliberate act; a missing confirm
returns `invalid_params` explaining exactly that. The response carries an explicit-risk sentence
("You are restoring a file ClamAV flagged; only do this if you are certain it is a false positive.")
so an agent quoting the result surfaces the risk to whoever reads it. Errors: `not_found` for an
unknown id, `conflict` if the file was already restored or purged (state rides in `data`). This tool
gives agents parity with the human restore control (owner ruling, 10).

### set_policy

Input: a partial policy object; unknown keys are rejected with `invalid_params` naming the key.
The mount-hold key additionally requires `confirm: true` in the same call, because it changes
system behavior (mounts pause until scanned); the error for a missing confirm explains exactly
that. Returns the full updated policy.

## Contract tests

The tool schemas above are the source of truth for a generated JSON fixture,
`mcp/contract/tools.json`, produced from the server's registered tools at build time. Two gates
consume it: the drift gate (08) that renders the public capability table, and a round-trip test in
07 that replays one canned call per tool against a daemon running on a seeded mock database and
asserts response shape. A tool added without fixtures fails the build, which is what keeps this
document honest over time.
