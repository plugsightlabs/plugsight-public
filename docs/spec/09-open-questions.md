# 09. Open questions and locked assumptions

This spec was written in one non-interactive session. Where a decision was needed and the sources
were silent, the best expert call was made and recorded in place; this file is the ledger. Locked
assumptions are safe to build on unless the owner overrules them. Open questions genuinely need
the owner (or reality) before or during the build.

## Locked assumptions (overrule before the affected node starts, or they stand)

| # | Assumption | Where | Overrule before |
|---|---|---|---|
| A1 | Local API is JSON-RPC 2.0 over a Unix domain socket, not loopback HTTP | 02 | N4 |
| A2 | GRDB is the SQLite layer | 02, 06 | N2 |
| A3 | ClamAV is user-installed (Homebrew, guided from Settings), not bundled | 02, 05 | N7 |
| A4 | Scoring is deterministic and explainable; no ML in v1 (no labeled corpus, and the timeline needs line-by-line reasoning) | 05 | N3 |
| A5 | Trust tier `none` displays as "Default" in both faces; tier consequence lines are shared copy | 04 | N9/N10 |
| A6 | Alerts auto-resolve when the condition ends; acknowledge is a human/agent act, resolve is a system act | 04, 06 | N2 |
| A7 | ES AUTH handlers fail open (a crashed monitor must not brick mounting) | 02 | N12 |
| A8 | Event retention defaults to 365 days with a prune-marker event | 06 | N2 |
| A9 | Repo is private during the pre-1.0 build, flipped public at the v1.0 launch (owner ruling); one tree, no scrubbed mirror, developed as if already public so no secrets ever land | 08 | v1.0 launch |
| A10 | English-only v1; layout does not bake in English widths | 04 | N10 |
| A11 | The app is not sandboxed and does not target the Mac App Store (the daemon, socket, and ES extension make MAS a poor fit); distribution is Developer ID only | 02, 08 | N1 |
| A12 | Eject stays GUI-only (a standard OS operation, not a Plugsight capability). Restore-from-quarantine gets full agent parity via `restore_quarantine` (owner ruling, superseding the v1 human-only default; see Q5 and 10) | 04, 03 | resolved |

## Owner rulings requested (design conflicts surfaced by the canon review)

| # | Question | Interim decision in the spec |
|---|---|---|
| Q1 | Action-free empty states: the canon says every state offers a next action; a monitor's truthful empty state ("nothing has plugged in") has no honest action. | Allowed as a deliberate exception, stated per surface (04). |
| Q2 | Disabled-control reasons: canon offers "reason a hover away" but also bans hover-only reveals and demands focus-reachable tooltips. | Inline visible text on the disabled row (the accessible side) (04). |
| Q3 | Notification actions (macOS notification buttons) were cut as duplication of the alert surface. | Cut for v1; revisit if dogfooding shows the round-trip hurts. |
| Q4 | A dedicated quarantine browser was cut as speculative. | Quarantine lives inside scan records; revisit on real use. |
| Q5 | Should an agent be able to restore quarantined files (`restore_quarantine` tool)? Restoring attacker-adjacent files is deliberately human-gated in v1. | RESOLVED: owner ruled full agent parity. `restore_quarantine` exists (03), gated by `confirm:true` and carrying explicit-risk copy. See 10. |

## Genuinely open (need the owner or a spike)

1. **Apple developer account and the ES entitlement (gated N12 distribution). RESOLVED
   2026-09-04.** The personal account K4GPUAV422 applies (D2). The Endpoint Security client
   entitlement was requested 2026-08-26 (07 N0) and **GRANTED by Apple 2026-09-04**. Ground truth
   is the Apple Developer console, not the grant email; confirm the capability shows enabled there
   before the distribution build. The 08 fallback (ship without the extension target, capability
   table saying so) is what the app does today and remains correct until the live N12 gate
   confirms the hold path on a SIP-relaxed machine. Turn-on runbook: `docs/RELEASE-ES-RUNBOOK.md`.
2. **TCC attribution spike (early risk, affects N6/N11).** Input Monitoring prompts for a
   launchd-agent daemon must attribute to Plugsight in the System Settings UI. This is a known
   rough edge. If attribution misbehaves, the fallback design is to host the event tap in the app
   process instead of the daemon (the seam allows it: the scorer consumes a stream, it does not
   care which process feeds it). Spike this in week one, before N6 hardens.
3. **Mount-hold mechanics (N12 risk).** Denying the user-visible mount and scanning "the volume"
   requires a private mount or raw-device read to have something to scan. The exact mechanism
   (temporary private mountpoint owned by the daemon vs deferring the scan to first user mount)
   needs a spike; if the private mount proves fragile, the honest fallback is "hold until the
   user confirms" rather than "hold until scanned", and the toggle copy changes accordingly.
4. **Name clearance.** Partly cleared: npm (`plugsight`, `plugsight-mcp`, and `@plugsight/mcp` are
   all free) and the GitHub org (`plugsightlabs`, live, since the bare `plugsight` org was a dormant
   empty squat) are done. Still open before the public flip: the `plugsight.com` (or similar)
   domain, an `@plugsight` npm org claim if the scoped package name is kept, and a trademark search
   glance. Cheap now, expensive after launch.
5. **Bundling ClamAV later.** A3 keeps v1 simple, but "install Homebrew first" is a real filter
   for Maya-persona users. If dogfooding shows the Settings-guided install converting badly,
   bundling (with freshclam management and its notarization implications) becomes a v1.x project.
6. **Scoring calibration data.** The thresholds in 05 are literature-and-reasoning starting
   values. The charter forbids telemetry, so calibration data is the owner's own dogfood traces
   plus community-contributed fixture files (a documented `plugsight export-trace` path would let
   users donate anonymized timing fixtures deliberately). Decide whether to build that export in
   v1 or wait.
7. **File-level exfiltration auditing (T4).** ES file events on mounted volumes could give
   per-file write visibility at real cost (volume, noise, FDA). Explicitly deferred; revisit for
   v2 only with a concrete user story.
8. **Localization.** de-CH would be the owner's natural second locale. Deferred; the structural
   rule (no baked-in widths, copy in one strings table) keeps the door open.
9. **Homebrew cask timing.** After two or three stable tagged releases, submit the cask; earlier
   invites churn in a registry that dislikes it.
10. **macOS version floor.** The spec assumes macOS 13+. If dogfooding hardware or ES API
    convenience argues for 14+, decide before N1 pins deployment targets.
