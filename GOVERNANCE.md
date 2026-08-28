# Governance

Plugsight is a small, MIT-licensed, local-first project under the `plugsightlabs` GitHub org. This document explains who does what and how decisions get made. It is short on purpose: the project is maintained part-time, so the process is lightweight by design.

## Roles

**Users** run Plugsight, file issues, and report bugs. A clear bug report with reproduction steps, a documentation fix, or a well-scoped feature request all move the project forward; you do not need to write code to help.

**Contributors** open pull requests. Anyone can become a contributor by sending a change. Work on a short-lived branch and open a pull request into `develop`, the default branch and integration trunk. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to build the project and the gate a change has to pass.

**Maintainer.** Plugsight is led by a single maintainer (a BDFL model) under the `plugsightlabs` org. The maintainer reviews and merges pull requests, triages issues, cuts releases, and holds the final say on what lands and on the charter below. Releases promote in one direction only: `develop` to `staging` to `main`, where they are tagged. Pushes to the protected branches and production releases are owner-gated.

## How decisions are made

Most decisions happen in the open, on issues and pull requests, by lazy consensus: a change that has been reviewed, has no unresolved objection, and passes the gate (`ops/gate.sh`) can be merged. When a decision is unclear or contested, the maintainer decides, and the decision is final. We aim to explain the reasoning rather than just rule.

Binding design and scope decisions are recorded in [`docs/spec/10-owner-decisions.md`](docs/spec/10-owner-decisions.md). That file is the authoritative decision record: build work treats it as binding, and on any conflict with an earlier document, it wins. New decisions of that weight are appended there rather than left in an issue thread.

## The charter (not up for negotiation in a pull request)

Some properties of Plugsight are product law. A change that weakens any of these is rejected regardless of how good the rest of it is.

- **Detector, not blocker.** Plugsight detects and explains. It does not block, prevent, intercept, or guarantee against a hardware attack, and it never implies that it does. Where the OS blocks, the credit goes to the OS and the mechanism is named. The full Honesty Charter lives in [`docs/spec/00-overview.md`](docs/spec/00-overview.md).
- **Local-first, no telemetry.** Nothing leaves the machine by default. Any change to that would have to be opt-in and loudly documented.
- **The honesty drift gate.** The user-facing capability list is generated from the real software surface. `ops/check-drift.mjs` fails the build on drift, and no change may route around it to let the docs overclaim.
- **House style.** No em dashes or en dashes in prose; English only; the name is `Plugsight`. The release pipeline refuses a changelog section that contains an em dash.

## Scope

Plugsight is the local-first, MIT-licensed, macOS-native core. Fleet management, MDM integration, enforcement policy engines, and non-macOS platforms are out of scope for this repository (see the scope section of [`docs/spec/00-overview.md`](docs/spec/00-overview.md)). The architecture keeps a clean collector seam for possible later platforms, but the core stays a personal, local tool.

## Becoming a maintainer

Additional maintainers are added by invitation from the current maintainer, on the strength of sustained, high-quality contributions: good pull requests, helpful reviews, and sound judgement on the charter. There is no application form.

## Code of conduct

Participation is governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report unacceptable behavior through the private channel named there.
