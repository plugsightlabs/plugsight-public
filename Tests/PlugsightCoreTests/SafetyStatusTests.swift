// SafetyStatusTests.swift
//
// Exhaustive unit tests for the derived per-device SafetyStatus (docs/spec/04,
// "The verdict model"). The rules under test, from the spec:
//
//   red    — last scan infected, an active critical alert, or behavior high.
//   yellow — scan failed, unacked warning alerts, behavior elevated, stale
//            definitions weakening a clean verdict.
//   green  — clean scan (storage) or no adverse signals (non-storage), no
//            active alerts, behavior not elevated, applicable sensors on.
//   grey   — never scanned, scanner missing, or the deciding sensor off.
//            Grey is never red: zero information never renders as danger.
//
// Reasons are ordered most severe first; the status word is the worst
// applicable; each reason carries exactly one recommended action.

import XCTest
@testable import PlugsightCore

final class SafetyStatusTests: XCTestCase {

    // MARK: - Input builders

    /// A quiet storage drive with a clean scan: the canonical green.
    private func cleanDrive() -> SafetyInputs {
        SafetyInputs(
            isStorage: true, hasHIDInterface: false,
            lastScanState: "clean", scanning: false,
            activeCriticalAlerts: 0, activeWarningAlerts: 0,
            behaviorScore: nil, behaviorConfidence: nil,
            typingSensor: .active,
            scannerAvailable: true, scanOnMount: true,
            definitionsAgeDays: 1, definitionsWarnDays: 7)
    }

    /// A quiet keyboard with the typing sensor on: the canonical non-storage green.
    private func quietKeyboard() -> SafetyInputs {
        SafetyInputs(
            isStorage: false, hasHIDInterface: true,
            lastScanState: nil, scanning: false,
            activeCriticalAlerts: 0, activeWarningAlerts: 0,
            behaviorScore: nil, behaviorConfidence: nil,
            typingSensor: .active,
            scannerAvailable: true, scanOnMount: true,
            definitionsAgeDays: 1, definitionsWarnDays: 7)
    }

    private func reasonIDs(_ s: SafetyStatus) -> [String] { s.reasons.map(\.id) }

    // MARK: - Green

    func testCleanStorageDeviceIsGreen() {
        let s = SafetyStatus.derive(cleanDrive())
        XCTAssertEqual(s.status, .green)
        XCTAssertEqual(reasonIDs(s), ["all.clear"])
        XCTAssertEqual(s.reasons.first?.action, SafetyAction.none)
    }

    func testQuietNonStorageDeviceIsGreen() {
        let s = SafetyStatus.derive(quietKeyboard())
        XCTAssertEqual(s.status, .green)
        XCTAssertEqual(reasonIDs(s), ["all.clear"])
    }

    func testNonStorageNonHIDDeviceIsGreenEvenWithSensorOff() {
        // A hub has no typing to check: the typing sensor does not apply.
        var i = quietKeyboard()
        i.hasHIDInterface = false
        i.typingSensor = .off
        XCTAssertEqual(SafetyStatus.derive(i).status, .green)
    }

    func testCleanScanWhileRescanningStaysGreen() {
        var i = cleanDrive()
        i.scanning = true
        XCTAssertEqual(SafetyStatus.derive(i).status, .green)
    }

    func testCleanScanWithScannerNowMissingStaysGreen() {
        // The drive WAS checked; losing the scanner later does not erase that.
        var i = cleanDrive()
        i.scannerAvailable = false
        XCTAssertEqual(SafetyStatus.derive(i).status, .green)
    }

    func testBehaviorBelowWarningThresholdStaysGreen() {
        var i = quietKeyboard()
        i.behaviorScore = 30
        i.behaviorConfidence = .high
        XCTAssertEqual(SafetyStatus.derive(i).status, .green)
    }

    // MARK: - Red

    func testInfectedScanIsRed() {
        var i = cleanDrive()
        i.lastScanState = "infected"
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .red)
        XCTAssertEqual(s.reasons.first?.id, "scan.infected")
        XCTAssertEqual(s.reasons.first?.action, .reviewQuarantine)
    }

    func testActiveCriticalAlertIsRed() {
        var i = quietKeyboard()
        i.activeCriticalAlerts = 1
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .red)
        XCTAssertEqual(s.reasons.first?.id, "alert.critical")
        XCTAssertEqual(s.reasons.first?.action, .reviewAlerts)
    }

    func testBehaviorHighIsRed() {
        var i = quietKeyboard()
        i.behaviorScore = 90
        i.behaviorConfidence = .medium
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .red)
        XCTAssertEqual(s.reasons.first?.id, "behavior.high")
        XCTAssertEqual(s.reasons.first?.action, .unplug)
    }

    func testBehaviorHighAtExactCriticalThresholdIsRed() {
        var i = quietKeyboard()
        i.behaviorScore = Tuning.default.criticalScoreThreshold
        i.behaviorConfidence = .high
        XCTAssertEqual(SafetyStatus.derive(i).status, .red)
    }

    // MARK: - Yellow

    func testFailedScanIsYellow() {
        var i = cleanDrive()
        i.lastScanState = "failed"
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .yellow)
        XCTAssertEqual(s.reasons.first?.id, "scan.failed")
        XCTAssertEqual(s.reasons.first?.action, .scanAgain)
    }

    func testActiveWarningAlertIsYellow() {
        var i = quietKeyboard()
        i.activeWarningAlerts = 2
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .yellow)
        XCTAssertEqual(s.reasons.first?.id, "alert.warning")
        XCTAssertEqual(s.reasons.first?.action, .reviewAlerts)
    }

    func testBehaviorElevatedIsYellow() {
        var i = quietKeyboard()
        i.behaviorScore = 70
        i.behaviorConfidence = .high
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .yellow)
        XCTAssertEqual(s.reasons.first?.id, "behavior.elevated")
        XCTAssertEqual(s.reasons.first?.action, .unplug)
    }

    func testHighScoreWithLowConfidenceIsYellowAtMostAndStatesUncertainty() {
        // S5c: a plausible misattribution (typing may be from another keyboard)
        // renders yellow at most, never a hard "Unsafe".
        var i = quietKeyboard()
        i.behaviorScore = 95
        i.behaviorConfidence = .low
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .yellow)
        XCTAssertEqual(s.reasons.first?.id, "behavior.uncertain")
        XCTAssertTrue(s.reasons.first?.sentence.contains("another keyboard") == true)
    }

    func testStaleDefinitionsWeakenACleanVerdictToYellow() {
        var i = cleanDrive()
        i.definitionsAgeDays = 8   // warn days default 7
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .yellow)
        XCTAssertEqual(s.reasons.first?.id, "definitions.stale")
        XCTAssertEqual(s.reasons.first?.action, .updateDefinitions)
    }

    func testDefinitionsAtExactlyWarnDaysAreNotStale() {
        var i = cleanDrive()
        i.definitionsAgeDays = 7
        XCTAssertEqual(SafetyStatus.derive(i).status, .green)
    }

    func testUnknownDefinitionsAgeDoesNotClaimStaleness() {
        var i = cleanDrive()
        i.definitionsAgeDays = nil
        XCTAssertEqual(SafetyStatus.derive(i).status, .green)
    }

    func testStaleDefinitionsDoNotTouchNonStorageDevices() {
        var i = quietKeyboard()
        i.definitionsAgeDays = 99
        XCTAssertEqual(SafetyStatus.derive(i).status, .green)
    }

    // MARK: - Grey (not checked)

    func testNeverScannedStorageIsGrey() {
        var i = cleanDrive()
        i.lastScanState = nil
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertEqual(s.reasons.first?.id, "scan.never")
        XCTAssertEqual(s.reasons.first?.action, .scanAgain)
    }

    func testNeverScannedSentenceNamesScanOnMountWhenOff() {
        var i = cleanDrive()
        i.lastScanState = nil
        i.scanOnMount = false
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertTrue(s.reasons.first?.sentence.contains("turned off") == true,
                      "the sentence says why: plug-in scanning is off")
    }

    func testScannerMissingIsGreyWithInstallAction() {
        var i = cleanDrive()
        i.lastScanState = nil
        i.scannerAvailable = false
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertEqual(s.reasons.first?.id, "scanner.missing")
        XCTAssertEqual(s.reasons.first?.action, .installScanner)
    }

    func testSkippedScanIsGrey() {
        var i = cleanDrive()
        i.lastScanState = "skipped"
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertEqual(s.reasons.first?.id, "scan.skipped")
        XCTAssertEqual(s.reasons.first?.action, .scanAgain)
    }

    func testCanceledScanIsGrey() {
        var i = cleanDrive()
        i.lastScanState = "canceled"
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertEqual(s.reasons.first?.id, "scan.canceled")
    }

    func testFirstScanRunningIsGreyNotBlank() {
        var i = cleanDrive()
        i.lastScanState = nil
        i.scanning = true
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertEqual(s.reasons.first?.id, "scan.running")
        XCTAssertEqual(s.reasons.first?.action, SafetyAction.none)
    }

    func testHIDDeviceWithSensorOffIsGrey() {
        var i = quietKeyboard()
        i.typingSensor = .off
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertEqual(s.reasons.first?.id, "sensor.off")
        XCTAssertEqual(s.reasons.first?.action, .grantInputMonitoring)
    }

    func testHIDDeviceWithSensorRestartRequiredIsGrey() {
        var i = quietKeyboard()
        i.typingSensor = .restartRequired
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertEqual(s.reasons.first?.id, "sensor.restart")
        XCTAssertEqual(s.reasons.first?.action, .restartDaemon)
    }

    func testStorageHIDComboWithSensorOffIsGreyDespiteCleanScan() {
        // BadUSB shape: a drive that also types. The clean scan answers the
        // storage question, but the typing question is unanswered.
        var i = cleanDrive()
        i.hasHIDInterface = true
        i.typingSensor = .off
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey)
        XCTAssertEqual(reasonIDs(s), ["sensor.off"])
    }

    // MARK: - Grey is never red; severity ordering

    func testAllGreyConditionsTogetherNeverRenderRedOrYellow() {
        let i = SafetyInputs(
            isStorage: true, hasHIDInterface: true,
            lastScanState: nil, scanning: false,
            activeCriticalAlerts: 0, activeWarningAlerts: 0,
            behaviorScore: nil, behaviorConfidence: nil,
            typingSensor: .off,
            scannerAvailable: false, scanOnMount: true,
            definitionsAgeDays: nil, definitionsWarnDays: 7)
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .grey, "zero information never renders as danger")
        XCTAssertTrue(s.reasons.count >= 2, "each unanswered question is its own reason")
    }

    func testRealDangerStillWinsOverMissingInformation() {
        // A critical alert on a never-scanned drive is red: grey never MASKS danger.
        var i = cleanDrive()
        i.lastScanState = nil
        i.activeCriticalAlerts = 1
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .red)
        XCTAssertEqual(s.reasons.first?.id, "alert.critical")
        XCTAssertTrue(reasonIDs(s).contains("scan.never"), "the unanswered question still rides along")
    }

    func testReasonsOrderedMostSevereFirstAndWordIsTheWorst() {
        var i = cleanDrive()
        i.lastScanState = "infected"
        i.activeWarningAlerts = 1
        i.hasHIDInterface = true
        i.typingSensor = .off
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .red)
        XCTAssertEqual(reasonIDs(s), ["scan.infected", "alert.warning", "sensor.off"])
    }

    func testYellowBeatsGrey() {
        var i = cleanDrive()
        i.lastScanState = nil
        i.activeWarningAlerts = 1
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(s.status, .yellow)
        XCTAssertEqual(reasonIDs(s), ["alert.warning", "scan.never"])
    }

    // MARK: - Wire shape

    func testWireShapeFieldNames() throws {
        var i = cleanDrive()
        i.lastScanState = "infected"
        let data = try JSONEncoder().encode(SafetyStatus.derive(i))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["status"] as? String, "red")
        let reasons = try XCTUnwrap(obj["reasons"] as? [[String: Any]])
        let first = try XCTUnwrap(reasons.first)
        XCTAssertEqual(first["id"] as? String, "scan.infected")
        XCTAssertEqual(first["action"] as? String, "reviewQuarantine")
        XCTAssertNotNil(first["sentence"] as? String)
    }

    // MARK: - Vocabulary rules (04 shared vocabulary)

    /// Every reachable reason, produced by driving derive() across the input space.
    private func allReasons() -> [SafetyReason] {
        var inputs: [SafetyInputs] = []
        for scanState in [nil, "clean", "infected", "failed", "skipped", "canceled"] as [String?] {
            for scanning in [false, true] {
                for scannerAvailable in [false, true] {
                    for scanOnMount in [false, true] {
                        var i = cleanDrive()
                        i.lastScanState = scanState
                        i.scanning = scanning
                        i.scannerAvailable = scannerAvailable
                        i.scanOnMount = scanOnMount
                        i.definitionsAgeDays = 30
                        inputs.append(i)
                    }
                }
            }
        }
        for sensor in [TypingSensorState.active, .restartRequired, .off] {
            for (score, conf) in [(nil, nil), (95, BehavioralScore.Confidence.low), (95, .high), (70, .high)] as [(Int?, BehavioralScore.Confidence?)] {
                var i = quietKeyboard()
                i.typingSensor = sensor
                i.behaviorScore = score
                i.behaviorConfidence = conf
                i.activeCriticalAlerts = 1
                i.activeWarningAlerts = 1
                inputs.append(i)
            }
        }
        return inputs.flatMap { SafetyStatus.derive($0).reasons }
    }

    func testNoSentenceUsesInternalNamesOrEmDashes() {
        for r in allReasons() {
            XCTAssertFalse(r.sentence.contains("\u{2014}"), "no em dashes: \(r.sentence)")
            for banned in ["IOKit", "clamd", "ClamAV", "CoreGraphics", "EndpointSecurity", "daemon", "HID"] {
                XCTAssertFalse(r.sentence.contains(banned),
                               "internal name '\(banned)' leaked into: \(r.sentence)")
            }
        }
    }

    func testEverySentenceIsANonEmptyPeriodTerminatedSentence() {
        for r in allReasons() {
            XCTAssertFalse(r.sentence.isEmpty)
            XCTAssertTrue(r.sentence.hasSuffix("."), "sentence ends with a period: \(r.sentence)")
            XCTAssertFalse(r.id.isEmpty)
        }
    }

    func testReasonIDsAreUniqueWithinOneStatus() {
        var i = cleanDrive()
        i.lastScanState = "infected"
        i.activeCriticalAlerts = 2
        i.activeWarningAlerts = 3
        i.hasHIDInterface = true
        i.typingSensor = .off
        i.behaviorScore = 95
        i.behaviorConfidence = .high
        i.definitionsAgeDays = 99
        let s = SafetyStatus.derive(i)
        XCTAssertEqual(Set(reasonIDs(s)).count, s.reasons.count, "no duplicate reason ids")
    }
}
