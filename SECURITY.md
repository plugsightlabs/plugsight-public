# Security policy

Plugsight is a security product, so we hold its own reporting process to the same bar we ask of the software: precise, private, and honest about scope.

## Supported versions

Plugsight is early and pre-1.0. There is no long-term support window yet. Security fixes land on the latest release line only. Run a current version; the single source of truth for the current version is `ops/version.json`.

## Reporting a vulnerability

Report security issues privately. Do not open a public issue, discussion, or pull request for a vulnerability.

Use GitHub's private security advisories:

- https://github.com/plugsightlabs/plugsight/security/advisories/new

This opens a private channel visible only to you and the maintainers. Include enough detail to reproduce the issue (macOS version, hardware, the device or input involved, and the steps), and tell us if you would like to be credited in the fix.

We are a small team working part-time, so please allow time for a response. Please give us a reasonable window to ship a fix before any public disclosure.

## Scope

In scope: the daemon (`plugsightd`) and its local API, the menu-bar app, the MCP server under `mcp/`, the Endpoint Security extension, the release and drift tooling under `ops/`, and any privilege, isolation, or data-handling flaw in them.

Out of scope by design, and stated so no report is filed against a limit Plugsight never claimed to cover:

- Plugsight is a detector, not a blocker. That it does not prevent a device from acting is a documented property, not a vulnerability. See [`docs/spec/01-threat-model.md`](docs/spec/01-threat-model.md).
- An attacker with root on the host can unload any monitoring, including Plugsight. This is out of the threat model (limit L10); the daemon records gaps in its own uptime so the absence of data is at least legible.
- Behavioral scoring is probabilistic and evadable. A specific evasion is expected, not a security hole; see the evasion notes in the threat model.

## Security posture

Several of Plugsight's defenses are structural rather than configurable:

- **Local-first, no telemetry.** Nothing leaves the machine. There is no analytics and no phone-home. If that ever changed it would be opt-in and loudly documented; it is not built today.
- **Local API behind a per-boot auth token.** The daemon exposes one local JSON-RPC-over-UDS API guarded by a token minted per boot. The menu-bar app and the MCP server are peer clients of that same API.
- **The daemon writes, the faces ask.** All monitoring, scoring, scanning, storage, and policy live in the daemon. The human UI and the agent-facing MCP server are thin clients; neither carries its own copy of the security logic.
- **Signed and notarized distribution.** Release builds are code-signed with a Developer ID and notarized by Apple, and shipped outside the Mac App Store. The release pipeline runs a secret scan (`gitleaks`) as a fatal gate because this repo is public from day one.

Treat the machine running Plugsight as trusted. Plugsight tells you honestly what plugged in and what it did; it does not turn an untrusted host into a trusted one.
