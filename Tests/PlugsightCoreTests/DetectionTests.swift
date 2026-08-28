// DetectionTests.swift
//
// N3's test surface (07). The four scoring vectors below are the FROZEN
// contract: a change to these numbers is a behavior change, not a cleanup.
// If the implementation does not hit them, fix the implementation.

import XCTest
@testable import PlugsightCore

final class DetectionTests: XCTestCase {

    // MARK: - Behavioral score: the four frozen vectors (07, verbatim)

    func testInjectorProfileScores85() {
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
        let s = BehavioralScore.compute(latencyMs: 45000, meanIKIMs: 110, stddevIKIMs: 40,
                                        keystrokes: 200, redundantKeyboard: true, descriptorOddity: false)
        XCTAssertLessThan(s.score, 60)       // must NOT alert; evasion is real and tested as real
    }

    func testMidRampLatency() {
        let s = BehavioralScore.compute(latencyMs: 1250, meanIKIMs: 150, stddevIKIMs: 55,
                                        keystrokes: 20, redundantKeyboard: false, descriptorOddity: false)
        XCTAssertEqual(s.score, 18)          // round(100*0.35*0.5)
    }

    // MARK: - Confidence ladder

    func testConfidenceLowUnderTwelveKeystrokes() {
        // Injector-grade signals, but only 5 keystrokes: evidence too thin.
        let s = BehavioralScore.compute(latencyMs: 300, meanIKIMs: 20, stddevIKIMs: 2,
                                        keystrokes: 5, redundantKeyboard: true, descriptorOddity: true)
        XCTAssertEqual(s.confidence, .low)
    }

    func testAmbiguousAttributionForcesLowConfidence() {
        // Same profile as the injector vector, but attribution is ambiguous
        // (two keyboards typing in the same window): the scorer says so.
        let s = BehavioralScore.compute(latencyMs: 410, meanIKIMs: 21, stddevIKIMs: 3,
                                        keystrokes: 47, redundantKeyboard: true, descriptorOddity: false,
                                        ambiguousAttribution: true)
        XCTAssertEqual(s.confidence, .low)
    }

    func testConfidenceMediumWithEnoughKeysButSingleSignal() {
        // >= 12 keys, only the latency signal above 0.5: medium, not high.
        let s = BehavioralScore.compute(latencyMs: 400, meanIKIMs: 150, stddevIKIMs: 60,
                                        keystrokes: 40, redundantKeyboard: false, descriptorOddity: false)
        XCTAssertEqual(s.confidence, .medium)
    }

    func testConfidenceHighNeedsThirtyKeysAndTwoStrongSignals() {
        // Two strong signals but only 20 keys: medium, not high.
        let s = BehavioralScore.compute(latencyMs: 400, meanIKIMs: 20, stddevIKIMs: 3,
                                        keystrokes: 20, redundantKeyboard: false, descriptorOddity: false)
        XCTAssertEqual(s.confidence, .medium)
    }

    func testTimingSignalGatedBelowTwelveKeystrokes() {
        // Injector cadence but under the 12-key gate: s_timing must be 0, so
        // only latency contributes. round(100*0.35*1.0) = 35.
        let s = BehavioralScore.compute(latencyMs: 300, meanIKIMs: 20, stddevIKIMs: 2,
                                        keystrokes: 11, redundantKeyboard: false, descriptorOddity: false)
        XCTAssertEqual(s.score, 35)
    }

    func testEmptyIntervalSampleContributesZeroTiming() {
        // The false-positive: a slow, deliberate human types >= 12 keys, but
        // every inter-key gap exceeds the burst window and is dropped, so the
        // interval sample is EMPTY. mean and stddev then arrive as 0, which the
        // ramps would otherwise read as maximal sub-30 ms injector cadence.
        // An empty sample must contribute ZERO timing suspicion.
        let s = BehavioralScore.compute(latencyMs: 5000, meanIKIMs: 0, stddevIKIMs: 0,
                                        keystrokes: 15, intervalCount: 0,
                                        redundantKeyboard: false, descriptorOddity: false)
        XCTAssertEqual(s.signals.timing, 0, "empty interval sample must not read as injector cadence")
        XCTAssertEqual(s.score, 0, "no signal is present, so nothing may spike the score")
    }

    func testInsufficientIntervalSampleContributesZeroTiming() {
        // Same guard for a non-empty but too-thin sample: 15 keys but only a
        // few surviving intervals is not a burst we can judge cadence on.
        let s = BehavioralScore.compute(latencyMs: 5000, meanIKIMs: 20, stddevIKIMs: 2,
                                        keystrokes: 15, intervalCount: 3,
                                        redundantKeyboard: false, descriptorOddity: false)
        XCTAssertEqual(s.signals.timing, 0, "a sample below the burst size cannot fire the timing signal")
    }

    func testSufficientIntervalSampleStillFiresInjectorCadence() {
        // Guard the real signal: a full sample with near-uniform sub-30 ms
        // cadence MUST still score timing 1.0 (the injector shape survives).
        let s = BehavioralScore.compute(latencyMs: 5000, meanIKIMs: 21, stddevIKIMs: 3,
                                        keystrokes: 47, intervalCount: 46,
                                        redundantKeyboard: false, descriptorOddity: false)
        XCTAssertEqual(s.signals.timing, 1, "a full injector-cadence sample must still fire timing")
    }

    // MARK: - No magic numbers by construction

    func testTuningParameterChangesScore() {
        // The compute signature exposes `tuning:`; widening latencyZeroMs must
        // move the mid-ramp case. Default: (2000-1250)/1500 = 0.5 -> 18.
        // Widened: (2750-1250)/2250 = 0.666… -> round(100*0.35*0.666…) = 23.
        var tuning = Tuning.default
        tuning.latencyZeroMs = 2750
        let s = BehavioralScore.compute(latencyMs: 1250, meanIKIMs: 150, stddevIKIMs: 55,
                                        keystrokes: 20, redundantKeyboard: false, descriptorOddity: false,
                                        tuning: tuning)
        XCTAssertNotEqual(s.score, 18)
        XCTAssertEqual(s.score, 23)
    }

    // MARK: - Class-mismatch rules R1-R6 (05 table)

    private func iface(_ seq: Int, _ cls: Int, _ sub: Int = 0, _ proto: Int = 0) -> InterfaceDescriptor {
        InterfaceDescriptor(seq: seq, usbClass: cls, usbSubclass: sub, usbProtocol: proto)
    }

    private func device(
        _ interfaces: [InterfaceDescriptor],
        vendorName: String? = "Acme",
        productName: String? = "Gadget",
        vid: Int = 0x1234,
        pid: Int = 0x5678,
        previousInterfaceCount: Int? = nil,
        serialChangedAcrossAttaches: Bool = false
    ) -> MismatchInput {
        MismatchInput(
            vid: vid, pid: pid,
            vendorName: vendorName, productName: productName,
            interfaces: interfaces,
            previousInterfaceCount: previousInterfaceCount,
            serialChangedAcrossAttaches: serialChangedAcrossAttaches
        )
    }

    private func rules(of findings: [MismatchFinding]) -> [MismatchRule] {
        findings.map(\.rule)
    }

    func testR1HiddenKeyboardStoragePrimaryIsCritical() {
        // The BadUSB signature shape: presents as mass storage, also types.
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x08, 0x06, 0x50),      // mass storage (primary presentation)
            iface(1, 0x03, 0x01, 0x01),      // hidden HID keyboard
        ]))
        let r1 = findings.first { $0.rule == .r1HiddenKeyboard }
        XCTAssertNotNil(r1)
        XCTAssertEqual(r1?.severity, .critical)
        // R1 subsumes R4 here: one critical alert, not a critical plus a
        // warning about the same two interfaces.
        XCTAssertFalse(rules(of: findings).contains(.r4KeyboardPlusStorage))
    }

    func testR1HiddenKeyboardVendorOnlyPrimaryIsCritical() {
        // A "charger" (vendor-only presentation) has no business typing.
        let findings = MismatchRules.evaluate(device([
            iface(0, 0xFF),                  // vendor-specific presentation
            iface(1, 0x03, 0x01, 0x01),      // hidden HID keyboard
        ]))
        let r1 = findings.first { $0.rule == .r1HiddenKeyboard }
        XCTAssertNotNil(r1)
        XCTAssertEqual(r1?.severity, .critical)
    }

    func testR2HiddenNetworkIsCritical() {
        // A storage stick that also enumerates CDC ECM: covert network path.
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x08, 0x06, 0x50),      // mass storage
            iface(1, 0x02, 0x06, 0x00),      // CDC ECM control
            iface(2, 0x0A, 0x00, 0x00),      // CDC data
        ]))
        let r2 = findings.first { $0.rule == .r2HiddenNetwork }
        XCTAssertNotNil(r2)
        XCTAssertEqual(r2?.severity, .critical)
    }

    func testR3KeyboardPlusNetworkIsCritical() {
        // Classic implant combo, no consumer precedent.
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x03, 0x01, 0x01),      // HID keyboard
            iface(1, 0x02, 0x0D, 0x00),      // CDC NCM control
        ]))
        let r3 = findings.first { $0.rule == .r3KeyboardPlusNetwork }
        XCTAssertNotNil(r3)
        XCTAssertEqual(r3?.severity, .critical)
        // R3 names the combo; the same evidence must not also fire R2.
        XCTAssertFalse(rules(of: findings).contains(.r2HiddenNetwork))
    }

    func testR4KeyboardPlusStorageIsWarningNotR1() {
        // Keyboard-primary device with a "driver CD" partition: R4 warning,
        // NOT R1 critical — R1 needs a non-keyboard primary presentation.
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x03, 0x01, 0x01),      // HID keyboard (primary)
            iface(1, 0x08, 0x06, 0x50),      // mass storage
        ]))
        let r4 = findings.first { $0.rule == .r4KeyboardPlusStorage }
        XCTAssertNotNil(r4)
        XCTAssertEqual(r4?.severity, .warning)
        XCTAssertFalse(rules(of: findings).contains(.r1HiddenKeyboard))
    }

    func testR5LateInterfaceIsWarning() {
        // Re-enumerated with MORE interfaces than its first enumeration this
        // session: mode-switching after trust inspection.
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x08, 0x06, 0x50),
            iface(1, 0x08, 0x06, 0x50),
            iface(2, 0x08, 0x06, 0x50),
        ], previousInterfaceCount: 1))
        let r5 = findings.first { $0.rule == .r5LateInterface }
        XCTAssertNotNil(r5)
        XCTAssertEqual(r5?.severity, .warning)
    }

    func testR5NotFiredOnSameOrFewerInterfaces() {
        let same = MismatchRules.evaluate(device([iface(0, 0x08, 0x06, 0x50)],
                                                 previousInterfaceCount: 1))
        XCTAssertFalse(rules(of: same).contains(.r5LateInterface))
        let first = MismatchRules.evaluate(device([iface(0, 0x08, 0x06, 0x50)],
                                                  previousInterfaceCount: nil))
        XCTAssertFalse(rules(of: first).contains(.r5LateInterface))
    }

    func testR6EmptyStringsOnKeyboardIsNotice() {
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x03, 0x01, 0x01),
        ], vendorName: "", productName: nil))
        let r6 = findings.first { $0.rule == .r6DescriptorAnomaly }
        XCTAssertNotNil(r6)
        XCTAssertEqual(r6?.severity, .notice)
    }

    func testR6SerialChangeAcrossAttachesIsNotice() {
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x08, 0x06, 0x50),
        ], serialChangedAcrossAttaches: true))
        let r6 = findings.first { $0.rule == .r6DescriptorAnomaly }
        XCTAssertNotNil(r6)
        XCTAssertEqual(r6?.severity, .notice)
    }

    func testR6NotFiredOnNamedKeyboard() {
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x03, 0x01, 0x01),
        ], vendorName: "Typo Corp", productName: "Clacker"))
        XCTAssertFalse(rules(of: findings).contains(.r6DescriptorAnomaly))
    }

    func testPlainKeyboardMatchesNoRule() {
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x03, 0x01, 0x01),
        ]))
        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - Allowlist (shipped as data, matches SHAPES not VID/PID)

    private func shippedAllowlist() throws -> Allowlist {
        try Allowlist.loadShipped()
    }

    func testShippedAllowlistLoadsFourShapes() throws {
        let allowlist = try shippedAllowlist()
        XCTAssertEqual(allowlist.patterns.count, 4)
    }

    func testSecurityKeyShapeDowngradesToAllowlistedInfo() throws {
        // A YubiKey-style device: vendor-primary + OTP keyboard + CCID.
        // Without the allowlist this is R1 critical; the FIDO shape
        // downgrades it to a single info event naming the pattern.
        let input = device([
            iface(0, 0xFF),                  // vendor-specific (FIDO)
            iface(1, 0x03, 0x01, 0x01),      // OTP keyboard HID
            iface(2, 0x0B),                  // CCID smartcard
        ])
        let bare = MismatchRules.evaluate(input)
        XCTAssertTrue(rules(of: bare).contains(.r1HiddenKeyboard))

        let findings = MismatchRules.evaluate(input, allowlist: try shippedAllowlist())
        XCTAssertEqual(findings.filter { $0.severity == .critical }.count, 0)
        let info = findings.first { $0.kind == "mismatch.allowlisted" }
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.severity, .info)
        XCTAssertEqual(info?.allowlistedPattern, "security-key")
    }

    func testKeyboardWithHubShapeDowngradesToAllowlistedInfo() throws {
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x03, 0x01, 0x01),      // keyboard
            iface(1, 0x09),                  // hub
            iface(2, 0x03, 0x01, 0x02),      // mouse
        ]), allowlist: try shippedAllowlist())
        let info = findings.first { $0.kind == "mismatch.allowlisted" }
        XCTAssertEqual(info?.severity, .info)
        XCTAssertEqual(info?.allowlistedPattern, "keyboard-with-hub")
    }

    func testWebcamShapeDowngradesToAllowlistedInfo() throws {
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x0E),                  // video
            iface(1, 0x01),                  // audio
        ]), allowlist: try shippedAllowlist())
        let info = findings.first { $0.kind == "mismatch.allowlisted" }
        XCTAssertEqual(info?.severity, .info)
        XCTAssertEqual(info?.allowlistedPattern, "webcam")
    }

    func testDockShapeDowngradesToAllowlistedInfo() throws {
        // hub-primary + network would be R2 critical without the allowlist.
        let input = device([
            iface(0, 0x09),                  // hub
            iface(1, 0x02, 0x06, 0x00),      // CDC ECM network
            iface(2, 0x01),                  // audio
            iface(3, 0x11),                  // billboard
        ])
        let bare = MismatchRules.evaluate(input)
        XCTAssertTrue(rules(of: bare).contains(.r2HiddenNetwork))

        let findings = MismatchRules.evaluate(input, allowlist: try shippedAllowlist())
        XCTAssertEqual(findings.filter { $0.severity == .critical }.count, 0)
        let info = findings.first { $0.kind == "mismatch.allowlisted" }
        XCTAssertEqual(info?.severity, .info)
        XCTAssertEqual(info?.allowlistedPattern, "dock-adapter")
    }

    func testForgedVidPidDoesNotChangeAllowlistMatching() throws {
        // The allowlist matches interface shapes, never VID/PID: a forged
        // vendor id buys the attacker nothing here.
        let allowlist = try shippedAllowlist()
        let shape: [InterfaceDescriptor] = [
            iface(0, 0xFF), iface(1, 0x03, 0x01, 0x01), iface(2, 0x0B),
        ]
        let genuine = MismatchRules.evaluate(
            device(shape, vid: 0x1050, pid: 0x0407), allowlist: allowlist)   // Yubico
        let forged = MismatchRules.evaluate(
            device(shape, vid: 0xDEAD, pid: 0xBEEF), allowlist: allowlist)   // forged
        XCTAssertEqual(genuine, forged)
        XCTAssertNotNil(genuine.first { $0.kind == "mismatch.allowlisted" })
    }

    func testExtraHostileInterfaceBreaksTheShape() throws {
        // A "webcam" that also types is NOT the webcam shape: every interface
        // must be covered by the pattern, so the hidden keyboard voids the
        // match and the rules run at full severity.
        let findings = MismatchRules.evaluate(device([
            iface(0, 0x0E),                  // video
            iface(1, 0x01),                  // audio
            iface(2, 0x03, 0x01, 0x01),      // hidden keyboard
        ]), allowlist: try shippedAllowlist())
        XCTAssertNil(findings.first { $0.kind == "mismatch.allowlisted" })
    }

    func testAllowlistDoesNotSuppressR5R6() throws {
        // The allowlist gates R1-R4 only: a security-key-shaped device whose
        // serial mutates across attaches still raises the R6 notice.
        let findings = MismatchRules.evaluate(device([
            iface(0, 0xFF), iface(1, 0x03, 0x01, 0x01), iface(2, 0x0B),
        ], serialChangedAcrossAttaches: true), allowlist: try shippedAllowlist())
        XCTAssertTrue(rules(of: findings).contains(.r6DescriptorAnomaly))
    }

    // MARK: - Trust-tier interaction (05 semantics), a pure function

    func testTrustedSuppressesWarningButPassesCritical() {
        let warning = AlertDecision.forSeverity(.warning, tier: .trusted)
        XCTAssertFalse(warning.shouldAlert)
        let critical = AlertDecision.forSeverity(.critical, tier: .trusted)
        XCTAssertTrue(critical.shouldAlert)
        XCTAssertEqual(critical.effectiveSeverity, .critical)
    }

    func testMutedNeverNotifiesAtAnySeverity() {
        for severity in [DetectionSeverity.info, .notice, .warning, .critical] {
            XCTAssertFalse(AlertDecision.forSeverity(severity, tier: .muted).shouldAlert,
                           "muted must not notify at \(severity)")
        }
    }

    func testFlaggedNotifiesEverySeverity() {
        for severity in [DetectionSeverity.info, .notice, .warning, .critical] {
            XCTAssertTrue(AlertDecision.forSeverity(severity, tier: .flagged).shouldAlert,
                          "flagged must notify at \(severity)")
        }
    }

    func testDefaultTierAlertsWarningAndAboveOnly() {
        XCTAssertFalse(AlertDecision.forSeverity(.notice, tier: .none).shouldAlert)
        XCTAssertTrue(AlertDecision.forSeverity(.warning, tier: .none).shouldAlert)
        XCTAssertTrue(AlertDecision.forSeverity(.critical, tier: .none).shouldAlert)
    }

    func testBehavioralDefaultsWarningAt60CriticalAt85() {
        let below = AlertDecision.forScore(59, confidence: .medium, tier: .none)
        XCTAssertFalse(below.shouldAlert)
        let warning = AlertDecision.forScore(60, confidence: .medium, tier: .none)
        XCTAssertTrue(warning.shouldAlert)
        XCTAssertEqual(warning.effectiveSeverity, .warning)
        let critical = AlertDecision.forScore(85, confidence: .medium, tier: .none)
        XCTAssertTrue(critical.shouldAlert)
        XCTAssertEqual(critical.effectiveSeverity, .critical)
    }

    func testLowConfidenceNeverAlertsOnItsOwn() {
        // Renders in the device inspector as an observation instead.
        let d = AlertDecision.forScore(90, confidence: .low, tier: .none)
        XCTAssertFalse(d.shouldAlert)
    }

    func testFlaggedAlertsAtScore40() {
        let d = AlertDecision.forScore(40, confidence: .medium, tier: .flagged)
        XCTAssertTrue(d.shouldAlert)
        XCTAssertFalse(AlertDecision.forScore(39, confidence: .medium, tier: .flagged).shouldAlert)
    }

    func testTrustedSuppressesBehavioralWarningPassesCritical() {
        XCTAssertFalse(AlertDecision.forScore(70, confidence: .high, tier: .trusted).shouldAlert)
        XCTAssertTrue(AlertDecision.forScore(90, confidence: .high, tier: .trusted).shouldAlert)
    }

    func testMutedSuppressesBehavioralCritical() {
        XCTAssertFalse(AlertDecision.forScore(95, confidence: .high, tier: .muted).shouldAlert)
    }

    func testAlertThresholdsComeFromTuning() {
        // No magic numbers: raising the flagged threshold in Tuning moves
        // the decision.
        var tuning = Tuning.default
        tuning.flaggedScoreThreshold = 50
        let d = AlertDecision.forScore(45, confidence: .medium, tier: .flagged, tuning: tuning)
        XCTAssertFalse(d.shouldAlert)
    }

    func testTuningDefaultCarriesTheSpecConstants() {
        // 05's starting values, named. Frozen contract, additive-only after N3.
        let t = Tuning.default
        XCTAssertEqual(t.latencyFullMs, 500)
        XCTAssertEqual(t.latencyZeroMs, 2000)
        XCTAssertEqual(t.minKeystrokesForTiming, 12)
        XCTAssertEqual(t.meanFullMs, 35)
        XCTAssertEqual(t.meanZeroMs, 80)
        XCTAssertEqual(t.stddevFullMs, 12)
        XCTAssertEqual(t.stddevZeroMs, 40)
        XCTAssertEqual(t.latencyWeight, 0.35)
        XCTAssertEqual(t.timingWeight, 0.35)
        XCTAssertEqual(t.redundantWeight, 0.15)
        XCTAssertEqual(t.oddityWeight, 0.15)
        XCTAssertEqual(t.epochWindowSeconds, 120)
        XCTAssertEqual(t.redundantWindowSeconds, 600)
        XCTAssertEqual(t.highConfidenceKeystrokes, 30)
        XCTAssertEqual(t.strongSignalThreshold, 0.5)
        XCTAssertEqual(t.warningScoreThreshold, 60)
        XCTAssertEqual(t.criticalScoreThreshold, 85)
        XCTAssertEqual(t.flaggedScoreThreshold, 40)
    }
}
