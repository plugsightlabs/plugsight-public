// ScorerTests.swift
//
// N6 verify gate: the HID scorer engine, exercised via the real seam
// (AsyncStream<CollectorEvent> from FakeDeviceEventSource) over the
// Tests/Fixtures/hid-traces/*.json trace fixtures — the synthetic injector,
// the recorded human trace, and the adversarial traces (05). The
// patient-implant fixture asserts honest NON-detection as explicitly as the
// injector fixture asserts detection.
//
// Class names all start with "ScorerTests" so `swift test --filter ScorerTests`
// selects the whole N6 gate.

import XCTest
import Foundation
@testable import PlugsightDaemon
import PlugsightCore
import PlugsightTestKit

// MARK: - Shared helpers

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PlugsightDaemonTests/
        .deletingLastPathComponent() // Tests/
        .appendingPathComponent("Fixtures/hid-traces/\(name)")
}

private func loadTrace(_ name: String) throws -> HIDTrace {
    try HIDTrace.load(from: fixtureURL(name))
}

/// Replay a fixture through the REAL seam: FakeDeviceEventSource ->
/// AsyncStream<CollectorEvent> -> ScorerEngine.
private func replay(
    _ name: String,
    tuning: Tuning = .default,
    descriptorOddity: @escaping (DeviceDescriptor) -> Bool = { _ in false }
) async throws -> [ScorerFinding] {
    let trace = try loadTrace(name)
    let engine = ScorerEngine(
        tuning: tuning,
        clock: trace.makeAttachClock(),
        descriptorOddity: descriptorOddity
    )
    let source = trace.makeSource()
    try source.start()
    return await engine.score(source.events)
}

private func keyboardDescriptor(key: String) -> DeviceDescriptor {
    DeviceDescriptor(
        deviceKey: key, vid: 5824, pid: 10203, serial: nil,
        vendorName: "HID Keyboard", productName: "HID Keyboard",
        interfaces: [InterfaceDescriptor(seq: 0, usbClass: 3, usbSubclass: 1, usbProtocol: 1)],
        portPath: "2-1"
    )
}

private func storageDescriptor(key: String) -> DeviceDescriptor {
    DeviceDescriptor(
        deviceKey: key, vid: 2316, pid: 4096, serial: "S1", vendorName: "USB",
        productName: "DISK 2.0",
        interfaces: [InterfaceDescriptor(seq: 0, usbClass: 8, usbSubclass: 6, usbProtocol: 80)],
        portPath: "1-1"
    )
}

private extension Array where Element == ScorerFinding {
    var bursts: [ScorerFinding] { filter { $0.kind == "hid.typing_burst" } }
    var scoreChanges: [ScorerFinding] { filter { $0.kind == "score.changed" } }
}

// MARK: - Trace fixtures through the real seam

final class ScorerTests: XCTestCase {

    // MARK: Harness sanity

    func testTraceReplayLoadsInjectorFixture() throws {
        let trace = try loadTrace("injector.json")
        XCTAssertEqual(trace.attachTimes.count, 1)
        // 5 background keys + attach + 47 injector keys + detach
        XCTAssertEqual(trace.events.count, 54)
        guard case .attached(let device) = trace.events[5] else {
            return XCTFail("expected attached at index 5, got \(trace.events[5])")
        }
        XCTAssertEqual(device.deviceKey, "kb-injector")
        XCTAssertEqual(
            trace.attachTimes[0],
            HIDTrace.baseDate.addingTimeInterval(20),
            "attach clock time must come from the fixture's atMs"
        )
    }

    // MARK: injector.json — detection

    func testInjectorTraceScoresHighWithHighConfidence() async throws {
        let findings = try await replay("injector.json")

        XCTAssertEqual(findings.bursts.count, 1)
        XCTAssertEqual(findings.scoreChanges.count, 1)

        let burst = try XCTUnwrap(findings.bursts.first)
        XCTAssertEqual(burst.severity, "notice")
        XCTAssertEqual(burst.deviceKey, "kb-injector")
        XCTAssertEqual(burst.burst.keystrokes, 47)
        XCTAssertEqual(burst.burst.firstKeyLatencyMs, 410)
        XCTAssertTrue(burst.burst.redundantKeyboard, "background typing 20 s earlier makes the keyboard redundant")
        XCTAssertFalse(burst.burst.ambiguousAttribution)

        let change = try XCTUnwrap(findings.scoreChanges.first)
        let score = try XCTUnwrap(change.score)
        XCTAssertGreaterThanOrEqual(score.score, 85, "commercial injector cadence must score high")
        XCTAssertEqual(score.confidence, .high)
        // Detection: the default-tier alert decision fires.
        let decision = AlertDecision.forScore(score.score, confidence: score.confidence, tier: .none)
        XCTAssertTrue(decision.shouldAlert)
    }

    // MARK: human.json — no false positive

    func testHumanTraceScoresZero() async throws {
        let findings = try await replay("human.json")

        XCTAssertEqual(findings.bursts.count, 1)
        let burst = try XCTUnwrap(findings.bursts.first)
        XCTAssertEqual(burst.burst.keystrokes, 80)
        XCTAssertFalse(burst.burst.redundantKeyboard)

        let change = try XCTUnwrap(findings.scoreChanges.first)
        let score = try XCTUnwrap(change.score)
        XCTAssertEqual(score.score, 0, "human typing must not score at all")
        XCTAssertEqual(change.severity, "notice")
        let decision = AlertDecision.forScore(score.score, confidence: score.confidence, tier: .none)
        XCTAssertFalse(decision.shouldAlert)
    }

    // MARK: patient-implant.json — HONEST NON-DETECTION (load-bearing, 05/07)

    func testPatientImplantEvadesAndWeSaySo() async throws {
        let findings = try await replay("patient-implant.json")

        // The burst IS observed and recorded — nothing is hidden...
        XCTAssertEqual(findings.bursts.count, 1)
        let burst = try XCTUnwrap(findings.bursts.first)
        XCTAssertEqual(burst.burst.keystrokes, 200)
        XCTAssertTrue(burst.burst.redundantKeyboard)

        // ...but a patient implant that waits 45 s and types at human cadence
        // EVADES the behavioral score, and we say so instead of pretending.
        let change = try XCTUnwrap(findings.scoreChanges.first)
        let score = try XCTUnwrap(change.score)
        XCTAssertLessThan(score.score, 60, "patient implant must NOT reach the warning threshold")
        XCTAssertEqual(change.severity, "notice", "score.changed must carry notice, not warning")

        // MUST NOT alert — on the default tier AND even on the stricter
        // flagged tier (threshold 40).
        XCTAssertFalse(AlertDecision.forScore(score.score, confidence: score.confidence, tier: .none).shouldAlert)
        XCTAssertFalse(AlertDecision.forScore(score.score, confidence: score.confidence, tier: .flagged).shouldAlert)

        // Honest confidence: plenty of evidence (200 keys, unambiguous), so
        // this is a confident LOW score, not an uncertain one.
        XCTAssertEqual(score.confidence, .medium)
    }

    // MARK: ambiguous.json — attribution ambiguity forces low confidence

    func testAmbiguousOverlapForcesLowConfidence() async throws {
        let findings = try await replay("ambiguous.json")

        let changes = findings.scoreChanges
        XCTAssertEqual(changes.count, 2, "both overlapping epochs must report")
        XCTAssertEqual(Set(changes.map(\.deviceKey)), ["kb-a", "kb-b"])
        for change in changes {
            let score = try XCTUnwrap(change.score)
            XCTAssertEqual(
                score.confidence, .low,
                "\(change.deviceKey): two keyboards typing in one window cannot be attributed — never guess silently"
            )
            XCTAssertTrue(change.burst.ambiguousAttribution)
            XCTAssertFalse(
                AlertDecision.forScore(score.score, confidence: score.confidence, tier: .none).shouldAlert,
                "low confidence never alerts on its own"
            )
        }
    }

    // MARK: Epoch lifecycle

    func testEpochOpensOnHIDAttachAndClosesAtEpochWindow() {
        let base = HIDTrace.baseDate
        let engine = ScorerEngine(clock: { base })

        XCTAssertTrue(engine.ingest(.attached(keyboardDescriptor(key: "kb-x"))).isEmpty)

        // 119 s after attach: inside the 120 s epoch — attributed.
        let inWindow = engine.ingest(.inputActivity(
            InputTiming(at: base.addingTimeInterval(119), interKeyIntervalMs: nil)))
        XCTAssertTrue(inWindow.isEmpty, "epoch still open, nothing emitted yet")

        // 121 s after attach: past epochWindow — the epoch closes FIRST, so
        // this key is NOT attributed to the device.
        let afterWindow = engine.ingest(.inputActivity(
            InputTiming(at: base.addingTimeInterval(121), interKeyIntervalMs: nil)))
        XCTAssertEqual(afterWindow.bursts.count, 1)
        XCTAssertEqual(afterWindow.bursts.first?.burst.keystrokes, 1,
                       "only the in-window key is attributed")

        XCTAssertTrue(engine.finish().isEmpty, "the post-window key belongs to no epoch")
    }

    func testNonHIDAttachOpensNoEpoch() {
        let base = HIDTrace.baseDate
        let engine = ScorerEngine(clock: { base })
        XCTAssertTrue(engine.ingest(.attached(storageDescriptor(key: "stick"))).isEmpty)
        XCTAssertTrue(engine.ingest(.inputActivity(
            InputTiming(at: base.addingTimeInterval(1), interKeyIntervalMs: nil))).isEmpty)
        XCTAssertTrue(engine.finish().isEmpty, "a storage stick opens no typing epoch")
    }

    func testDetachClosesEpoch() {
        let base = HIDTrace.baseDate
        let engine = ScorerEngine(clock: { base })
        _ = engine.ingest(.attached(keyboardDescriptor(key: "kb-x")))
        _ = engine.ingest(.inputActivity(InputTiming(at: base.addingTimeInterval(1), interKeyIntervalMs: nil)))
        _ = engine.ingest(.inputActivity(InputTiming(at: base.addingTimeInterval(1.1), interKeyIntervalMs: 100)))

        let findings = engine.ingest(.detached(deviceKey: "kb-x", at: base.addingTimeInterval(5)))
        XCTAssertEqual(findings.bursts.count, 1, "detach closes the epoch and emits the burst")
        XCTAssertEqual(findings.bursts.first?.burst.keystrokes, 2)
        XCTAssertTrue(engine.finish().isEmpty)
    }

    // MARK: Burst thresholds

    func testBurstBelowMinKeystrokesGatesTimingAndForcesLowConfidence() {
        let base = HIDTrace.baseDate
        let engine = ScorerEngine(clock: { base })
        _ = engine.ingest(.attached(keyboardDescriptor(key: "kb-x")))
        // 5 injector-fast keys — below minKeystrokesForTiming (12).
        var at = base.addingTimeInterval(0.4)
        _ = engine.ingest(.inputActivity(InputTiming(at: at, interKeyIntervalMs: nil)))
        for _ in 0..<4 {
            at = at.addingTimeInterval(0.02)
            _ = engine.ingest(.inputActivity(InputTiming(at: at, interKeyIntervalMs: 20)))
        }
        let findings = engine.finish()
        let change = findings.scoreChanges.first
        XCTAssertEqual(change?.score?.confidence, .low, "< 12 keystrokes is low confidence")
        XCTAssertEqual(change?.score?.signals.timing, 0, "timing signal gates on evidence volume")
    }

    func testEmptyIntervalSampleFromSlowTypistContributesNoTiming() {
        // Regression for the detection false-positive: a slow, deliberate human
        // types 15 keys, each gap > 2 s, so every interKeyIntervalMs arrives
        // nil (dropped as out-of-burst) and the interval sample is EMPTY. Even
        // though keystrokes >= minKeystrokesForTiming (12), the timing signal
        // must NOT fire — an empty sample is not injector cadence.
        let base = HIDTrace.baseDate
        let engine = ScorerEngine(clock: { base })
        _ = engine.ingest(.attached(keyboardDescriptor(key: "kb-slow")))
        var at = base.addingTimeInterval(5) // first key 5 s after plug-in
        _ = engine.ingest(.inputActivity(InputTiming(at: at, interKeyIntervalMs: nil)))
        for _ in 0..<14 {
            at = at.addingTimeInterval(3) // 3 s gaps -> all dropped to nil
            _ = engine.ingest(.inputActivity(InputTiming(at: at, interKeyIntervalMs: nil)))
        }
        let findings = engine.finish()
        let change = findings.scoreChanges.first
        XCTAssertEqual(change?.burst.keystrokes, 15, "all 15 keys are attributed")
        XCTAssertEqual(change?.score?.signals.timing, 0,
                       "an empty interval sample must contribute zero timing suspicion")
        XCTAssertEqual(change?.score?.score, 0,
                       "no signal is present, so the score must not spike")
    }

    func testRedundantKeyboardFlagRespectsWindow() {
        let base = HIDTrace.baseDate

        // Prior typing 30 s before attach (inside 600 s window) -> redundant.
        let engine = ScorerEngine(clock: { base.addingTimeInterval(30) })
        _ = engine.ingest(.inputActivity(InputTiming(at: base, interKeyIntervalMs: nil)))
        _ = engine.ingest(.attached(keyboardDescriptor(key: "kb-x")))
        _ = engine.ingest(.inputActivity(InputTiming(at: base.addingTimeInterval(31), interKeyIntervalMs: nil)))
        XCTAssertEqual(engine.finish().bursts.first?.burst.redundantKeyboard, true)

        // Prior typing 700 s before attach (outside the window) -> not redundant.
        let engine2 = ScorerEngine(clock: { base.addingTimeInterval(700) })
        _ = engine2.ingest(.inputActivity(InputTiming(at: base, interKeyIntervalMs: nil)))
        _ = engine2.ingest(.attached(keyboardDescriptor(key: "kb-y")))
        _ = engine2.ingest(.inputActivity(InputTiming(at: base.addingTimeInterval(701), interKeyIntervalMs: nil)))
        XCTAssertEqual(engine2.finish().bursts.first?.burst.redundantKeyboard, false)
    }

    // MARK: Descriptor oddity feeds the score

    func testDescriptorOddityFlagIsPassedThrough() async throws {
        // Same injector trace, with N3's oddity verdict injected: score rises
        // by the oddity weight (85 -> 100).
        let findings = try await replay("injector.json", descriptorOddity: { $0.deviceKey == "kb-injector" })
        let score = try XCTUnwrap(findings.scoreChanges.first?.score)
        XCTAssertTrue(findings.bursts.first?.burst.descriptorOddity == true)
        XCTAssertEqual(score.score, 100)
    }
}

// MARK: - Privacy wall (02, executable)

final class ScorerTestsPrivacyWall: XCTestCase {

    /// The 02 privacy wall made executable: `InputTiming` carries timing ONLY.
    /// If anyone ever adds a field that could carry a key code, character,
    /// usage, or content, this test fails.
    func testInputTimingCarriesTimingOnlyNoContentFields() {
        let mirror = Mirror(reflecting: InputTiming(at: Date(), interKeyIntervalMs: 20))
        let labels = mirror.children.map { $0.label ?? "<unlabeled>" }
        XCTAssertEqual(
            labels, ["at", "interKeyIntervalMs"],
            "InputTiming must have EXACTLY the two timing fields — nothing else, ever"
        )
        let types = mirror.children.map { String(describing: type(of: $0.value)) }
        XCTAssertEqual(
            types, ["Date", "Optional<Int>"],
            "timing fields must stay timestamp/interval types that cannot carry content"
        )
        for label in labels {
            let lower = label.lowercased()
            for banned in ["code", "char", "usage", "content", "text", "string", "scan", "symbol"] {
                XCTAssertFalse(
                    lower.contains(banned),
                    "field '\(label)' looks like it could carry typed content"
                )
            }
        }
    }
}

// MARK: - Degraded mode (02): tap creation fails -> capability false, no crash

private final class FailingTap: KeyTimingTap {
    private(set) var startCalls = 0
    func start(onKeyDown: @escaping @Sendable (Date) -> Void) -> Bool {
        startCalls += 1
        return false // Input Monitoring not granted
    }
    func stop() {}
}

private final class GrantedFakeTap: KeyTimingTap {
    private(set) var handler: (@Sendable (Date) -> Void)?
    func start(onKeyDown: @escaping @Sendable (Date) -> Void) -> Bool {
        handler = onKeyDown
        return true
    }
    func stop() { handler = nil }
}

final class ScorerTestsDegradedMode: XCTestCase {

    func testTapCreateFailureReportsCapabilityFalseAndKeepsRunning() {
        let tap = FailingTap()
        let scorer = HIDScorer(engine: ScorerEngine(), tap: tap)

        let capability = scorer.start() // must not throw, must not crash
        XCTAssertEqual(tap.startCalls, 1)
        XCTAssertFalse(capability.behavioralScoring, "missing grant -> capability reported false")
        XCTAssertFalse(scorer.capability.behavioralScoring)

        // Enumeration signals still flow: attach/detach pass through the
        // scorer unharmed even with behavioral scoring off.
        XCTAssertTrue(scorer.ingest(.attached(storageDescriptor(key: "stick"))).isEmpty)
        XCTAssertTrue(scorer.ingest(.detached(deviceKey: "stick", at: Date())).isEmpty)
        XCTAssertTrue(scorer.finish().isEmpty)
    }

    func testGrantedTapReportsCapabilityTrueAndFeedsEngine() {
        let tap = GrantedFakeTap()
        let base = HIDTrace.baseDate
        let scorer = HIDScorer(engine: ScorerEngine(clock: { base }), tap: tap)

        XCTAssertTrue(scorer.start().behavioralScoring)

        _ = scorer.ingest(.attached(keyboardDescriptor(key: "kb-x")))
        tap.handler?(base.addingTimeInterval(0.5))
        tap.handler?(base.addingTimeInterval(0.52))

        let findings = scorer.finish()
        XCTAssertEqual(findings.filter { $0.kind == "hid.typing_burst" }.first?.burst.keystrokes, 2,
                       "tap keydowns must reach the engine as timing-only input activity")
    }
}
