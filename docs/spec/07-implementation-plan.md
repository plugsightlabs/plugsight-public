# 07. Implementation plan (the build graph)

> **For agentic workers:** this plan is written to be executed by a /graph-build session using
> parallel maker subagents with checker review, superpowers:subagent-driven-development style.
> Nodes are independently verifiable units. Steps use checkbox syntax. Every node ends in a commit;
> a node that did not commit did not happen.

**Goal:** build Plugsight v1 exactly as specified in docs 00-06 and 08: daemon, ES extension,
local API, MCP server, menu-bar app, ship pipeline.

**Architecture:** one Swift daemon owning collector, scorer, analyzer, ClamAV orchestration,
SQLite store, and a JSON-RPC-over-UDS API; a separate ES system extension feeding it over XPC; a
thin TypeScript MCP adapter; a SwiftUI menu-bar client. See 02.

**Tech stack:** Swift 5.10+ / SwiftPM, GRDB (SQLite), IOKit, IOHIDManager, CoreGraphics event
taps, EndpointSecurity, DiskArbitration, SwiftUI, SMAppService; TypeScript with
`@modelcontextprotocol/sdk`; ClamAV as an external binary.

## Execution rules (bind every subagent)

1. Every node runs in its own worktree on its own `claude/<node-id>` branch and **commits per
   logical unit**, never once at the end. "Do not commit" is forbidden as a coordination
   mechanism.
2. A node is done when its verify gate passes **on disk** (checker re-runs the command; the
   maker's claim is not evidence), and the branch is merged to `develop`, pushed, worktree
   closed.
3. Makers receive: this doc's node section, the spec sections it cites, and the contract files
   listed under "shared state". They do not receive other nodes' reasoning.
4. Checkers receive: the node's spec sections, the diff, and the verify gate. They run the gate
   themselves and read the code against the spec. A checker that only reads the maker's summary
   has not checked.
5. TDD throughout: the failing test is written and seen failing before the implementation.
6. No placeholder steps. If a maker hits a genuine unknown, it records the question in
   `docs/spec/09-open-questions.md` (committed) and takes the most conservative option that keeps
   its gate green.

## Shared state (the contracts between nodes)

| Artifact | Written by | Frozen after | Consumed by |
|---|---|---|---|
| `Sources/PlugsightCore/Contracts/CollectorEvent.swift` (event enum, device/interface structs, `DeviceEventSource` protocol per 02) | N1 | N1 merge | N2, N3, N5, N6, N12 |
| `Sources/PlugsightCore/Contracts/APITypes.swift` (request/response DTOs per 02's method table) | N4 | N4 merge | N9, N10 |
| SQLite schema migrations (06 DDL) | N2 | additive-only after N2 | N3, N4, N7, N8 |
| `mcp/contract/tools.json` (generated, 03) | N9 | regenerated each build | N14 |
| `DetectionTuning.swift` (every 05 constant, named) | N3 | additive-only | N6 |

Changing a frozen contract requires a graph-level decision, not a node-level edit: the
orchestrator reopens the owning node, and dependents re-verify.

## The graph

```
N0 (ES entitlement application, external wait)  ..........................
N1 scaffold ─┬─> N2 store ─┬─> N3 detection ──> N6 scorer ─┐             :
             │             ├─> N4 api ────┬──> N9 mcp ──> N14 drift-gate :
             │             └─> N7 clamav  │               │              :
             └─> N5 collector ────────────┴─> N8 daemon <─┘   N12 esext <─
                                               │  │            │
                                               │  └─> N10 ui ─> N11 onboarding
                                               └────────────────┴─> N13 ship
```

Execution batches (each batch's nodes run as parallel maker subagents):

| Batch | Nodes | Note |
|---|---|---|
| 0 | N0, N1 | N0 is a human action started on day one; nothing else waits on it except N12's distribution build |
| 1 | N2, N5 | both depend only on N1's contracts |
| 2 | N3, N4, N7 | all depend on N2 |
| 3 | N6, N9, N12 | N6 needs N3+N5; N9 needs N4; N12 needs N1 (+N0 for distribution, not for dev) |
| 4 | N8, then N10 | wiring first, UI against the running daemon |
| 5 | N11, N14 | onboarding on the UI; drift gate on the MCP contract |
| 6 | N13 | packaging, release checklist |

## Nodes

### N0: ES entitlement application (external, start immediately)

Not code. The owner applies for `com.apple.developer.endpoint-security.client` on the developer
account via Apple's request form, on day one, because the wait is measured in weeks and gates only
N12's distribution build (L5). **Verify gate:** the request confirmation exists; status is tracked
in 09. Dev work on N12 proceeds on a SIP-relaxed test machine meanwhile.

### N1: scaffold and contracts

**Files:** `Package.swift` (targets: `PlugsightCore` with no IOKit/CoreGraphics imports,
`PlugsightDaemon`, `plugsightd` executable, test targets), `Sources/PlugsightCore/Contracts/CollectorEvent.swift`,
`mcp/package.json` + `mcp/tsconfig.json` (workspace stub), `ops/check-seam.sh`.

- [ ] Write `CollectorEvent.swift` exactly as 02's seam specifies: the `DeviceEventSource`
      protocol, `CollectorEvent` enum with cases `attached(DeviceDescriptor)`,
      `detached(deviceKey:at:)`, `interfacesRead`, `volumeMounted`, `volumeUnmounted`,
      `inputActivity(InputTiming)`; `DeviceDescriptor` and `InterfaceDescriptor` structs carrying
      only 06's vocabulary (ints, strings, dates).
- [ ] Write the seam gate `ops/check-seam.sh`: `swift build --target PlugsightCore` then grep the
      target's sources for `import IOKit|import CoreGraphics|import EndpointSecurity`; any hit
      exits 1.
- [ ] Write one compile-level test that a trivial `FakeDeviceEventSource` (array-backed
      AsyncStream) satisfies the protocol; this fake lives in a `PlugsightTestKit` target and is
      the backbone of all later detection tests.
- [ ] Commit per step. **Verify gate:** `swift build && swift test && ops/check-seam.sh` green,
      `npm --prefix mcp install && npm --prefix mcp run build` green on the stub.

### N2: store and migrations

**Files:** `Sources/PlugsightCore/Store/` (GRDB records, migrations transcribing 06's DDL
verbatim, `EventStore` API: append, queries with cursor pagination, retention pruning),
`Tests/PlugsightCoreTests/StoreTests.swift`.

- [ ] Failing tests first, one per behavior: migration produces the 06 schema (introspect
      `sqlite_master`); device upsert by identity key (serial case and shape-fingerprint case,
      including the two-identical-serialless-sticks case collapsing to one row); event append is
      the only write path for history; cursor pagination is stable newest-first across pages
      (7c acceptance); retention prune writes the marker event (06).
- [ ] Implement until green. GRDB, WAL, prepared statements only.
- [ ] **Verify gate:** `swift test --filter StoreTests` green; seam gate still green.

### N3: detection engine

**Files:** `Sources/PlugsightCore/Detection/` (`DetectionTuning.swift`, `MismatchRules.swift`,
`BehavioralScore.swift`, `Allowlist.swift` + `allowlist.json` resource),
`Tests/PlugsightCoreTests/DetectionTests.swift`.

This node is pure functions and the deepest test surface in the project. The 05 tables are the
test plan; transcribe every row into a fixture.

- [ ] Mismatch rules: one failing test per rule R1-R6 and per allowlist shape (security key,
      keyboard-with-hub, webcam, dock), including the R4-not-R1 severity distinction and the
      allowlist downgrading to `mismatch.allowlisted`.
- [ ] Scoring math, exact vectors (these numbers are the contract; a later refactor that changes
      them is a behavior change, not a cleanup):

```swift
func testInjectorProfileScores85() {
    // latency 410ms -> s=1.0 (past the 500ms full-suspicion point is clamped; 410 < 500 -> 1.0)
    // timing mean 21ms stddev 3ms over 47 keys -> s=1.0
    // redundant keyboard present -> 1.0; no descriptor oddity -> 0.0
    let s = BehavioralScore.compute(latencyMs: 410, meanIKIMs: 21, stddevIKIMs: 3,
                                    keystrokes: 47, redundantKeyboard: true, descriptorOddity: false)
    XCTAssertEqual(s.score, 85)          // 100*(0.35+0.35+0.15+0)
    XCTAssertEqual(s.confidence, .high)  // >=30 keys, >=2 signals over 0.5
}
func testHumanProfileScoresLow() {
    let s = BehavioralScore.compute(latencyMs: 6200, meanIKIMs: 145, stddevIKIMs: 60,
                                    keystrokes: 80, redundantKeyboard: false, descriptorOddity: false)
    XCTAssertEqual(s.score, 0)
}
func testPatientImplantEvadesAndWeSaySo() {
    // delayed start, humanized cadence: the honest-non-detection fixture from 05
    let s = BehavioralScore.compute(latencyMs: 45000, meanIKIMs: 110, stddevIKIMs: 40,
                                    keystrokes: 200, redundantKeyboard: true, descriptorOddity: false)
    XCTAssertLessThan(s.score, 60)       // must NOT alert; evasion is real and tested as real
}
func testMidRampLatency() {
    // 1250ms -> (2000-1250)/1500 = 0.5 on the latency ramp, other signals zero
    let s = BehavioralScore.compute(latencyMs: 1250, meanIKIMs: 150, stddevIKIMs: 55,
                                    keystrokes: 20, redundantKeyboard: false, descriptorOddity: false)
    XCTAssertEqual(s.score, 18)          // round(100*0.35*0.5)
}
```

- [ ] Confidence ladder tests (low under 12 keys; ambiguous attribution forces low).
- [ ] Trust-tier interaction tests: trusted suppresses warning, passes critical; flagged alerts
      at >= 40 (05 semantics).
- [ ] Every constant read from `DetectionTuning.swift`; a test asserts no magic numbers by
      construction (the compute function takes a `Tuning` parameter, defaulted).
- [ ] **Verify gate:** `swift test --filter DetectionTests` green.

### N4: local API server

**Files:** `Sources/PlugsightDaemon/API/` (UDS listener, newline-framed JSON-RPC 2.0 codec,
`auth.hello` gate, method routing to the store per 02's table, `event.appended` fanout,
`APITypes.swift` contract), `Tests/PlugsightDaemonTests/APITests.swift`.

- [ ] Framing and auth tests first, over a real socket in a temp dir: unauthenticated first
      message gets `-32001` and a closed connection; bad token likewise; hello returns
      apiVersion/capabilities; 0600 modes on socket and token file asserted.
- [ ] One test per method against a seeded in-memory store (every 02 table row), including error
      shapes (`not_found`, `invalid_params` with the offending key named, `conflict` on
      double-ack) and the actor stamping on mutations.
- [ ] Subscription test: `events.tail`, append via store, assert the notification arrives on the
      subscribed connection only; `events.untail` stops it.
- [ ] `policy.set` shallow-merge semantics and the `confirm:true` gate for mount-hold (8c).
- [ ] **Verify gate:** `swift test --filter APITests` green.

### N5: IOKit collector

**Files:** `Sources/PlugsightDaemon/Collector/IOKitDeviceSource.swift`,
`.../HIDTimingSource.swift`, `.../DiskArbitrationSource.swift`,
`Tests/PlugsightDaemonTests/CollectorMappingTests.swift`, `ops/dev-attach-probe.swift` (a tiny
manual CLI that prints CollectorEvents live, the developer's hardware smoke tool).

- [ ] The IOKit callback and registry-walking code cannot run in CI. Split it: pure mapping
      functions (io registry property dictionaries, captured as JSON fixtures from real devices,
      to `DeviceDescriptor`) are unit-tested; the notification plumbing is thin and exercised by
      the manual probe. Capture fixtures for at least: a keyboard, a serialless stick, a hub
      composite, a junk-strings device (2b's case).
- [ ] Implement first-match/terminated registration, interface walking, topology (port path),
      HID matching via IOHIDManager, DiskArbitration mount/unmount mapping to volume events.
- [ ] **Verify gate:** `swift test --filter CollectorMappingTests` green, plus a checker-run of
      `ops/dev-attach-probe.swift` on real hardware with one attach/detach (manual step, recorded
      in the node's PR description with pasted output).

### N6: HID scorer wiring

**Files:** `Sources/PlugsightDaemon/Scorer/` (CGEventTap lifecycle under Input Monitoring, epoch
manager, attribution per 05, degraded mode when the grant is missing),
`Tests/PlugsightDaemonTests/ScorerTests.swift`, `Tests/Fixtures/hid-traces/*.json`.

- [ ] The scorer's engine consumes `AsyncStream<CollectorEvent>` (the seam), so all logic tests
      run on trace fixtures: the synthetic injector trace, the recorded human trace, the
      adversarial traces (05's testing section). Write those fixtures and the replay harness in
      `PlugsightTestKit` first.
- [ ] Tests: epoch opens on HID-capable attach and closes at `epochWindow`; burst detection
      thresholds; attribution ambiguity forces low confidence; no key codes anywhere in stored
      structs (a reflection test asserts the `InputTiming` struct has no content field, the 02
      privacy wall made executable).
- [ ] CGEventTap plumbing itself: thin, plus degraded-mode test (tap creation fails -> capability
      reported false, enumeration signals still flow).
- [ ] **Verify gate:** `swift test --filter ScorerTests` green.

### N7: ClamAV orchestrator

**Files:** `Sources/PlugsightDaemon/Scanning/` (engine discovery, scan process runner with
timeout/cancel, output parser, quarantine mover, definitions-age reader),
`Tests/PlugsightDaemonTests/ScanningTests.swift`, `Tests/Fixtures/clamav/` (canned outputs).

- [ ] Tests run against a fake `clamscan` (a shell script fixture emitting canned output and exit
      codes 0/1/2), covering: verdict parsing, exit-2 renders `failed` never `clean`, timeout
      kills the process group and records `failed`, cancel records `canceled`, quarantine move
      with sidecar, read-only volume degrades to `reported_only` with the honest alert copy (05),
      missing engine yields the `skipped` event and `scanner_unavailable` error with the install
      fix.
- [ ] EICAR end-to-end against real ClamAV is a manual checklist item (works safely with the
      standard EICAR test string), not CI.
- [ ] **Verify gate:** `swift test --filter ScanningTests` green.

### N8: daemon assembly

**Files:** `Sources/plugsightd/main.swift` (wiring all sources into the analyzer/store/API,
degraded-capability computation, monitoring-gap detection on startup per L10, launchd agent
plist), `Tests/PlugsightDaemonTests/IntegrationTests.swift`.

- [ ] Integration tests on fakes: boot the daemon with `FakeDeviceEventSource` + in-memory store +
      real API socket; drive 02's canonical T1 data flow end to end and assert the exact event
      sequence and alert the walkthrough describes; assert `status.get` degraded reporting for
      each missing capability combination.
- [ ] Gap detection: daemon start writes `monitoring.gap` when last shutdown was unclean and the
      machine was up (system uptime vs last event).
- [ ] **Verify gate:** `swift test` (full suite) green.

### N9: MCP server

**Files:** `mcp/src/` (socket client, auth, the 19 tools of 03 with zod schemas, long-poll
`tail_events`, error mapping, contract generator emitting `mcp/contract/tools.json`),
`mcp/test/*.test.ts` with a mock daemon (a Node UDS server replaying canned API responses).

- [ ] Contract-first: transcribe 03's shapes into zod schemas; the generator dumps registered
      tools to `mcp/contract/tools.json` at build.
- [ ] One test per tool against the mock daemon (shape assertions), plus: `daemon_unreachable`
      mapping with the literal fix text, apiVersion refusal, caveat presence on `score_device`
      (03's grep-able requirement), long-poll returns early on event and empty at timeout.
- [ ] Round-trip stage (after N8 merges): replay one canned call per tool against the real daemon
      seeded via a `PLUGSIGHT_SEED_DB` dev flag; wired as `npm run test:roundtrip`, part of this
      node's gate once N8 is on develop.
- [ ] **Verify gate:** `npm --prefix mcp test` green; `tools.json` diff-clean against 03's
      inventory (same 18 names).

### N10: menu-bar app

**Files:** `App/` (SwiftUI app target: glyph item, popover, main window with Timeline / Devices /
Settings, device inspector, per 04's surface blocks), `App/Tests/` (view-model tests on the API
client against the mock daemon).

- [ ] View models first, tested against canned API payloads: every 04 surface state (loading
      skeleton, empty with its exact sentence, error with recovery, at-scale) exists as a
      view-model state with a test; the empty-state predicate is the list predicate (canon's data
      honesty rule, tested).
- [ ] Views: implement per surface block; glyph's four shapes differ in form not only tint;
      trust control applies immediately with undo toast.
- [ ] **Verify gate:** `swift test` green for view models, plus the build acceptance gates from
      04's canon check run on the real app: axe-equivalent accessibility audit via Accessibility
      Inspector on each surface, dark/light screenshots of every surface at normal and at-scale
      (20 seeded devices) reviewed by the checker with the canon, tap targets and spacing checked
      against Tier 2 numbers. Screenshot review is the gate; an unviewed UI does not merge.

### N11: onboarding and permissions

**Files:** `App/Onboarding/` (the four-step flow per 04's block, TCC state polling, SMAppService
registration, extension activation driving, /Applications location check).

- [ ] Step state machine tested pure (grant lands -> step completes; denial -> degraded copy with
      deep link; skip always available).
- [ ] Manual matrix run by the checker on a clean macOS VM: fresh install through 1a-1d including
      the deny paths, with screenshots. TCC prompt attribution verified here (02's known rough
      edge): the Input Monitoring prompt must name Plugsight.
- [ ] **Verify gate:** unit green + the VM walkthrough recorded in the PR.

### N12: ES system extension

**Files:** `ESExtension/` (extension target, ES client subscribing per 02, XPC listener with
code-sign requirement validation, policy cache, AUTH_MOUNT hold path fail-open),
`Tests/ESExtensionTests/` (decision logic pure-tested).

- [ ] All decision logic (should this mount be held, cache lookups, deadline budget) is pure and
      unit-tested; the ES plumbing is thin. AUTH handlers tested to answer ALLOW on any cache
      miss or error (fail-open, 02).
- [ ] XPC peer validation tested with a wrong-requirement fake where feasible; otherwise
      code-reviewed line by line by the checker against 02's security model, explicitly.
- [ ] Manual on the SIP-relaxed dev machine: activation flow, mount events arriving, a held mount
      releasing after a clean scan.
- [ ] **Verify gate:** unit green + manual session recorded. Distribution build additionally
      blocked on N0's grant; the graph treats that as a release gate, not a merge gate.

### N13: packaging and ship pipeline

Per 08. **Files:** `ops/release.mjs`, `ops/notarize.sh`, dmg build config, npm publish flow.

- [ ] Scripted end to end per 08's pipeline; dry-run mode tested in CI (everything except the
      actual notarization submit and npm publish).
- [ ] **Verify gate:** `node ops/release.mjs --dry-run` green; one real signed+notarized dmg
      produced and opened on a second machine (manual, checklist).

### N14: capability drift gate

Per 08. **Files:** `ops/check-drift.mjs`.

- [ ] Gate reads `mcp/contract/tools.json` + the daemon's emitted event-kind list (a
      `plugsightd --print-catalog` dev flag added here) and verifies README and docs tables
      match; verifies the score-caveat grep (03); fails the release script on any drift.
- [ ] **Verify gate:** deliberately introduce a drift in a test fixture and assert the gate
      fails; then green on the real tree.

## Testing strategy summary

- **Unit:** everything pure: detection math (exact vectors above), mismatch rules, store,
  framing, view models, ES decisions, MCP schemas.
- **Integration:** daemon on fakes + real socket (N8); MCP round-trip on seeded daemon (N9).
- **The ES gotchas:** ES cannot run in CI at all (entitlement + root + approval). Strategy:
  ruthlessly thin plumbing, pure decision logic, manual dev-machine sessions as recorded gate
  steps, fail-open verified in unit tests. Never mock the ES C API in depth; test above it.
- **HID scoring without a BadUSB device:** the trace-fixture harness (N6) replays synthetic
  injector, human, and adversarial traces through the real engine via the seam. The evasion
  fixture asserting non-detection is as load-bearing as the detection ones. Real-hardware smoke
  (any Digispark-class board) is a release-checklist item.
- **UI:** view-model states in unit tests; canon gates (contrast, a11y, dark/light, at-scale
  screenshots) as N10's reviewed evidence.
- **CI:** `swift build && swift test`, seam gate, `npm test`, drift gate dry-run, on every push.
  Manual gates are named steps in node PRs, never silently skipped.

## Self-review against the spec

Checked each spec section for a covering node: 02 components map to N4/N5/N6/N7/N8/N12; 03's
nineteen tools and contract fixtures to N9/N14; 04's surfaces and canon build-gates to N10/N11;
05's rules, math, tuning file, and trace strategy to N3/N6; 06's DDL and catalog to N2 (and the
`--print-catalog` flag in N14); 08's pipeline and gate to N13/N14; the Honesty Charter's testable
clauses land in N3 (evasion fixture), N9 (caveat test), N14 (drift). Type names used across nodes
(`CollectorEvent`, `DeviceEventSource`, `InputTiming`, `BehavioralScore.compute`, `Tuning`) are
defined in N1/N3 and referenced consistently. No task references an undefined artifact.
