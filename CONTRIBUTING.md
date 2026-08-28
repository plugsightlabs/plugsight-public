# Contributing to Plugsight

Thanks for your interest in Plugsight. This guide covers how to build it, the branch model, the gate a change has to pass, and the house rules that keep the project coherent.

Plugsight is a macOS-native, agent-first USB security monitor. It is a detector, not a blocker: it observes and scores USB and HID devices, scans mounted storage, and writes a plain-language timeline. It never claims to veto a device or stop a hardware attack. Any change that blurs that line will be rejected (see [The one hard line](#the-one-hard-line)).

## Ways to help

You do not need to write Swift to move Plugsight forward.

- **A bug or a feature idea.** Open an issue in [plugsightlabs/plugsight](https://github.com/plugsightlabs/plugsight/issues) and describe what a maintainer needs to reproduce or act on it.
- **A documentation fix.** The spec lives in [`docs/spec/`](docs/spec/) and is the source of truth for behavior; a clear correction there is as valuable as code.
- **A security issue.** Do not open a public issue. See [SECURITY.md](SECURITY.md) for private reporting.

For where to get help rather than give it, see [SUPPORT.md](SUPPORT.md). For how the project is governed, see [GOVERNANCE.md](GOVERNANCE.md).

## Building and testing

Plugsight is a Swift package (the daemon `plugsightd`, the menu-bar app `PlugsightApp`, and the shared `PlugsightCore`) plus a TypeScript MCP server under [`mcp/`](mcp/).

```bash
swift build            # build the daemon, the app, and the core
swift test             # run the Swift suite
( cd mcp && npm ci && npm run build && npm test )   # build and test the MCP server
```

`PlugsightCore` is platform-neutral by design and sits above a small collector seam, so most logic (detection, scoring, the API router, view models) is testable without a live socket or real hardware. Please keep it that way: new logic belongs behind the seam, not wired directly to IOKit.

### The gate

`ops/gate.sh` is the one composite gate. Run it before you push:

```bash
ops/gate.sh
```

It chains, in order: `swift build`, `swift test`, `ops/check-seam.sh` (the platform-neutral core stays free of platform types), the MCP build and test, and `node ops/check-drift.mjs` (the honesty drift gate, see below). A change that does not pass the gate is not ready.

A local pre-push hook that runs `ops/gate.sh` automatically enforces this on the integration branches (owner decision K-2 in [`docs/spec/10-owner-decisions.md`](docs/spec/10-owner-decisions.md)). It ships in the repo but is not auto-activated; install it once per clone with `node ops/install-hooks.mjs` (see the README for details). Until you install it, run the gate by hand before every push.

### The honesty drift gate

Plugsight's capability list is generated from the real software surface, so the docs cannot overclaim. `ops/check-drift.mjs` fails the build if the README or docs list more or fewer MCP tools or event kinds than the daemon actually registers (checked against `mcp/contract/tools.json` and `plugsightd --print-catalog`), or if a banned marketing claim appears outside a quoted negation. If you add or remove a tool or an event kind, regenerate the affected tables rather than editing them by hand.

## Branching and releases

Plugsight uses three long-lived branches:

- `develop` is the default branch where all changes integrate first. Open your pull requests against it.
- `staging` is a pre-release branch for verifying a batch of changes before release.
- `main` is the released branch. Releases are tagged from `main` by `ops/release.mjs`.

Work on a short-lived branch and open a pull request into `develop`. Changes promote in one direction only: `develop` to `staging` to `main`. Please do not open pull requests against `main` directly. The promotion between protected branches is owner-gated.

## Commit messages

Plugsight follows [Conventional Commits](https://www.conventionalcommits.org). Prefix the subject with a type (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, or `ci`) and a short imperative summary, for example `fix: stop the HID scorer from double-counting a re-enumerated keyboard`. Keep the subject near 72 characters. For a user-facing change, add a line under the top section of `CHANGELOG.md`. The single source of truth for the version is `ops/version.json`; run `node ops/sync-versions.mjs` after bumping it so the MCP package and the daemon constant agree.

## House style

- No em dashes and no en dashes in prose. Use a comma, a colon, parentheses, or a plain hyphen, or restructure the sentence. The release pipeline refuses to ship a changelog section that contains an em dash.
- English only.
- The product name is `Plugsight`, capitalized. The daemon is `plugsightd`, the app is `Plugsight.app`, the org is `plugsightlabs`.
- Keep every claim truthful to what Plugsight is. It detects and explains; it does not block, prevent, or guarantee. The [Honesty Charter](docs/spec/00-overview.md) is product law, and the drift gate enforces part of it mechanically.

## The one hard line

Never add a claim, a UI string, a doc line, or marketing copy that says or implies Plugsight blocks, prevents, intercepts, or guarantees against a hardware attack. On macOS, host software cannot veto a HID device, cannot see a dormant implant, and cannot make USB trust cryptographic. Plugsight scores and explains, and it says so on every surface. A change that overclaims is a release blocker, not a copy nit.

## Maintainer response time

Plugsight is maintained part-time by a small team under the `plugsightlabs` org. We read every issue and pull request, but reviews can take a while. Small, focused changes with clear reproduction steps get reviewed fastest.
