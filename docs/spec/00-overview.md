# 00. Overview: vision, scope, and the Honesty Charter

Plugsight is a macOS-native, agent-first USB security monitor. One sentence for what it does: it
answers "what plugged in, what did it claim to be, and what did it then do?" in plain language.

It is free, MIT-licensed, and macOS-only in v1. It is a detector, not a blocker, and it says so on
every surface.

## The legibility thesis

Every existing tool in this niche fails the same way: it either enforces silently or reports
illegibly. We reviewed the landscape before writing a line of this spec:

- USBGuard is Linux-only, enforce-first, and operated through an expert CLI and a rules DSL.
- swiftGuard is a macOS menu-bar kill switch: it reacts to a USB change by locking or shutting
  down. It does not explain anything.
- ClamUI-style wrappers scan mounted storage and stop there.
- DuckHunt attacked keystroke injection on Windows and has gone stale.
- Commercial DLP suites (device control modules from the big endpoint vendors) are capable, closed,
  and priced and designed for enterprises.

Nobody gives an individual Mac user, or an agent acting for one, a readable answer to the three
questions above. That answer is the product. Detection scores, interface tables, and scan results
all exist to feed one artifact: a forensic timeline a person can read without a security
background, and an agent can query without screen scraping.

Legibility is also why we refuse to block. A blocker must be right immediately and silently. A
monitor can be honest about confidence, show its reasoning, and let the human or the agent decide.
On macOS the platform makes the choice for us anyway (see the threat model), but we would make the
same choice on a platform that allowed blocking HID. Explanation is the differentiator; enforcement
is a commodity we deliberately leave to the OS.

## Agent-first, human-equal

Plugsight has one brain: a core daemon that owns monitoring, scoring, scanning, storage, and
policy. It exposes exactly one local API. Two peer clients sit on top:

- a SwiftUI menu-bar app for humans, and
- an MCP server (TypeScript, runs via `npx`) for agents.

Every capability a human has in the UI, an agent has as an MCP tool, because both are thin clients
of the same API. Neither face is a second-class port of the other. When an agent trusts a device or
kicks off a storage scan, the human sees the result in the timeline with the actor recorded, and
the reverse holds too.

## Scope of v1

In scope:

1. USB and HID attach/detach monitoring via IOKit notifications. Notification, never
   authorization.
2. Behavioral HID scoring for keystroke-injection likelihood (plug-to-type latency, inter-keystroke
   timing, a second keyboard appearing on a machine that already has one). Implemented with a
   listen-only CGEventTap under the Input Monitoring permission. Output is a 0 to 100 score with a
   stated confidence, never a block.
3. Class-mismatch detection: a device that presents as one thing (a charger, a storage stick) while
   also enumerating a hidden interface class such as a HID keyboard or a CDC/RNDIS network adapter.
   This is the strongest legible signal we have, and it gets a plain-language alert.
4. Mounted-storage scanning through ClamAV (orchestrating `clamscan` or `clamd` on volume mount),
   with quarantine and a readable report.
5. An Endpoint Security system extension for device-open and mount events, and for storage-open
   authorization where the platform genuinely allows it. The precise limits live in the threat
   model; the short version is that ES can gate userspace IOKit opens but cannot touch a HID
   keyboard, because IOHIDFamily binds keyboards in the kernel with no userspace open to intercept.
6. The readable forensic timeline: a SQLite event store, a human timeline window, and the same data
   over the API and MCP. Every device gets a record. Every event gets an explanation.
7. A trust and acknowledge flow: mark a device known, mute it, or flag it, from either face.
   Trust is keyed on identifiers a hostile device can forge, so trust raises the bar for alerting
   and never claims to be a guarantee. The UI copy says exactly that.

Out of scope for v1, with reasons:

- Pre-emptive blocking of HID devices. macOS gives third-party software no veto over HID
  enumeration. The only thing on the platform that does this is Apple's own accessory-approval
  prompt (Apple Silicon laptops, macOS Ventura and later; see 01 for the exact boundary). Plugsight
  complements that prompt. Claiming to replace it would be a lie.
- Detecting a dormant malicious cable. An implant that is not transmitting emits nothing the host
  can observe. Finding one takes RF equipment. No host software can do this, including ours.
- "Scanning a cable for malware." Physically impossible from the host side. The host sees USB
  descriptors and traffic, not firmware.
- Firmware vetting, DMA and Thunderbolt defense, and any non-macOS platform. Real problems, not
  this product, not this version.
- Enforcement policy engines, fleet management, MDM integration. Enterprise territory; v1 is a
  personal tool.

The architecture keeps a clean seam for later Linux and Windows collectors (Option A): the daemon
core is platform-neutral above a small collector interface, and the API and data model never leak
IOKit types. The seam is specified in 02. The collectors themselves are not.

## The Honesty Charter

This charter is product law. The UI, the README, the website, release notes, and any marketing
material must comply with it, and the docs-drift gate in 08 exists partly to enforce it. A claim
that contradicts the charter is a release blocker, not a copy nit.

1. Plugsight detects and explains. It does not block, and it never implies that it does. Where the
   OS blocks (Apple's accessory prompt, ES storage-open denial by policy), the credit goes to the
   OS and the specific mechanism is named.
2. Behavioral detection is probabilistic. Scores come with confidence and reasoning. We never
   describe detection as "catches BadUSB" without qualification, in any material, including a
   tweet.
3. A dormant implant is invisible to us. We say so, unprompted, in the docs and in the empty state
   of the timeline for a newly trusted cable.
4. Trust is a bar-raiser, not a guarantee. VID, PID, and serial can be forged by the attacker the
   feature nominally guards against. Copy that describes trust must carry this caveat the first
   time a user meets the feature.
5. Nothing leaves the machine. No telemetry, no phone-home, no cloud requirement. If that ever
   changes it will be opt-in and loudly documented, but the default posture of v1 is fully local.
6. What Plugsight cannot see, it does not invent. No fabricated confidence, no decorative precision
   ("87.3% malicious"), no red badges on zero-information states.
7. The capability list users read is generated from the real MCP tool surface, so it cannot drift
   from what the software does (08 specifies the gate).

Honesty is the moat. Every competitor either overclaims or hides. A security tool that states its
own limits earns the trust that makes its alerts worth reading.

## Document map

| Doc | Contents |
|---|---|
| 01-threat-model.md | What we defend against, what we cannot, macOS platform limits |
| 02-architecture.md | Daemon, ES extension, API, MCP, UI, storage, security model |
| 03-mcp-interface.md | The full agent-facing tool contract |
| 04-ux-stories.md | Personas, story matrix, IA, surfaces, flows, agent parity |
| 05-detection.md | HID scoring signals and math, class-mismatch rules, ClamAV |
| 06-data-model.md | SQLite schema and the event shape behind the timeline |
| 07-implementation-plan.md | The build graph: nodes, edges, verify gates, batches |
| 08-distribution.md | Org, npm, signing, ship pipeline, drift gate, dogfooding |
| 09-open-questions.md | Assumptions made in this spec and decisions still open |
| 10-owner-decisions.md | Owner decisions locked 2026-08-25; binding, wins on conflict |
