# 08. Distribution and operations

## Org, repo, license

- GitHub org `plugsightlabs`, MIT. The private **workshop** repo is `plugsightlabs/plugsight`
  (this tree); the user-facing **public mirror** is `plugsightlabs/plugsight-public`, an
  allowlisted, scrubbed, one-squashed-commit snapshot produced by `ops/publish-oss.mjs`. This is
  the workshop-plus-mirror model adopted in docs/spec/10 (2026-08-26), which supersedes this doc's
  earlier single-tree "no scrubbed public mirror" plan. The `plugsight` org handle was a dormant
  empty squat, so `plugsightlabs` is the namespace; the product, and the npm package, keep the bare
  `plugsight` name. The marketing `web/` and the internal docs never leave the workshop.
  Consequence: no secrets, tokens, personal identifiers, or third-party client data may ever enter
  the tree, and a secret scan (gitleaks) guards both the pre-push gate and the mirror publish, not a
  later addition.
- Default branch `develop`, promotion `develop -> main`, releases tagged from `main`. The release
  **tag** is pushed to the workshop (origin) for provenance; the user-facing **downloadable release
  and its dmg** are published to the public mirror `plugsightlabs/plugsight-public` (`ops/release.mjs`
  step 6, the `RELEASE_REPO` constant). No downloadable release is created on the private workshop.
- `docs/spec/` (these documents) stays in the repo. The spec being public is part of the honesty
  posture: anyone can read what the product claims it cannot do.

## Artifacts

| Artifact | Channel | Cadence |
|---|---|---|
| `Plugsight.app` (dmg, signed + notarized, daemon and ES extension inside) | GitHub Releases on the public mirror (`plugsightlabs/plugsight-public`); Homebrew cask once releases stabilize | tagged releases |
| `@plugsight/mcp` | npm, `npx @plugsight/mcp` | versioned with the app's apiVersion compatibility stated in its README |
| ClamAV | not ours; installed by the user (Homebrew), guided from Settings | n/a |

Version rule: the app and the MCP package version independently, but the MCP README and
`auth.hello` both state the supported `apiVersion`, and the release script refuses to publish an
MCP package whose declared `apiVersion` does not match the daemon it was built against.

## Signing and notarization

Developer ID certificates on the owner's Apple developer account. The release pipeline signs the
daemon, the ES extension (its entitlement per 02), and the app bundle; notarizes the dmg with
`notarytool`; staples the ticket. Windows-style unsigned escape hatches do not exist on macOS for
this product class: an unsigned build cannot activate its system extension, so signing is a build
requirement, not a distribution nicety. The ES entitlement grant (07 N0) must be on the account
before the first public release that includes the extension; if the grant is still pending at
launch, the release ships without the extension target and the capability table says so (the
degraded product is honest, the blocked release is not shipped half-signed).

## The ship pipeline

One command, `node ops/release.mjs`, modeled on the one-command publish pipeline proven in the
owner's other OSS project. Steps, in order, each fatal on failure:

1. Preflight: clean tree on `main`, version bumped in one place (`ops/version.json`, the single
   source all targets read), changelog entry present.
2. Gates: full Swift and TS test suites, the seam gate, the secret scan, and the drift gate
   (below).
3. Build: release-config app, dmg assembly.
4. Sign + notarize + staple (skippable only via `--dry-run`, which runs everything else).
5. npm publish of `@plugsight/mcp` with provenance (`npm publish --provenance` from CI or the
   release machine).
6. GitHub release: the tag is pushed to the workshop (origin) for provenance; the downloadable
   release and the dmg are uploaded to the public mirror (`plugsightlabs/plugsight-public`), with
   the changelog section as the release body. No downloadable release is made on the workshop.
7. Post-flight: download the published dmg fresh, verify signature and notarization
   (`spctl -a -vv`), run `npx @plugsight/mcp@latest` against the installed app, `get_status`
   green. The release is done when the published artifacts work, not when the upload returns 200.

## The capability drift gate

`ops/check-drift.mjs`, run in CI on every push and hard-required by the release script. It exists
so the README, the website, and the docs can never claim more (or less) than the software does:

- Reads `mcp/contract/tools.json` (generated from the registered tools at build, 03) and the
  daemon's `--print-catalog` output (event kinds, 06).
- Verifies the README capability table and the docs' tool inventory (03) list exactly those
  tools: no missing rows, no phantom rows.
- Verifies charter compliance greps: the score payload caveat string exists in the MCP source
  (03), and a banned-claims list ("blocks", "prevents", "stops BadUSB", "detects malicious
  cables") does not appear in README or website copy outside quoted negations. Crude on purpose:
  a grep that cries wolf occasionally is cheaper than a marketing claim that lies once.
- Fails with a diff-shaped message naming the drifted line, so fixing it is mechanical.

The gate is the enforcement arm of Honesty Charter item 7.

## Dogfooding

The owner runs Plugsight daily on their own Mac from the first N8 build onward, with a debug flag
capturing the real-typing traces that become N6's fixtures. Standing habits, written down so they
survive enthusiasm decay:

- Every release candidate runs on the owner's machine for at least two days before tagging.
- Every false positive or confusing sentence the owner meets becomes an issue with the timeline
  export attached; the event `summary` templates are tuned from real confusion, not taste.
- The owner's own MCP setup exercises the agent face weekly ("what plugged in this week,
  anything odd?"), so agent-side regressions surface as personally felt friction.
- The synthetic injector fixture is replayed against each release candidate (07's harness), and
  once a hardware injector board is in the drawer, the manual smoke test runs per release.

## Support surface

Issues and discussions on the GitHub repo, nothing else at launch. The README states the support
reality plainly (one maintainer, best effort) instead of imitating a company. Security reports:
a `SECURITY.md` with a private report channel (GitHub private vulnerability reporting) and an
honest response-time expectation.
