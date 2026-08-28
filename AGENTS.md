# AGENTS.md

Plugsight is agent-first. This file is the short pointer for an AI agent (or an agent-minded contributor) operating or extending it.

## The one idea

Plugsight has one brain: a core daemon (`plugsightd`) that owns all monitoring, scoring, scanning, storage, and policy, and exposes exactly one local API (JSON-RPC over a Unix domain socket, behind a per-boot auth token). Two peer clients sit on top:

- a SwiftUI menu-bar app for humans, and
- an MCP server (TypeScript, under [`mcp/`](mcp/), run via `npx`) for agents.

Every capability a human has in the UI, an agent has as an MCP tool, because both are thin clients of the same API. Neither face is a second-class port of the other. When an agent trusts a device or starts a scan, the human sees it in the timeline with the actor recorded, and the reverse holds too.

## Where to look

- [`docs/spec/03-mcp-interface.md`](docs/spec/03-mcp-interface.md) is the full agent-facing tool contract: the read tools, the write tools (each carrying its risk copy), and the long-poll for live events.
- [`mcp/contract/tools.json`](mcp/contract/tools.json) is the generated contract the drift gate checks. Do not hand-edit it; it is produced from the MCP client during the MCP build.
- [`docs/spec/00-overview.md`](docs/spec/00-overview.md) is the Honesty Charter, which is product law for anything you write to a user, including a single alert string.
- [`docs/spec/01-threat-model.md`](docs/spec/01-threat-model.md) is what Plugsight can and cannot see, and why.

## The charter, for an agent

Plugsight is a **detector, not a blocker**. When you generate any user-facing text (an alert, a summary, a report), never say or imply that Plugsight blocked, prevented, intercepted, or guaranteed against a device. It scores and explains. Behavioral scores are probabilistic and carry a confidence; report them that way. Where the OS is what blocked (Apple's accessory prompt, an Endpoint Security mount hold by policy), name that mechanism and give it the credit.

Write tools are real capabilities with consequences: `scan_storage`, `set_policy`, `trust_device`, `restore_quarantine`, and the rest change state. Treat a write as an action the human would want to see and, where the tool carries an explicit-risk or confirm requirement, honor it.

## The gate

Before you push a change, run the one composite gate:

```bash
ops/gate.sh
```

It runs `swift build`, `swift test`, the seam check, the MCP build and test, and the honesty drift gate (`node ops/check-drift.mjs`). The drift gate fails if the docs claim more or fewer tools or event kinds than the software registers, so if you change the tool surface, regenerate the tables rather than editing them by hand. The full contributor rules are in [CONTRIBUTING.md](CONTRIBUTING.md); the house style forbids em dashes in prose.
