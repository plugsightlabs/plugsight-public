import XCTest
@testable import PlugsightAppCore

/// The glyph's four states and the precedence rule stopped > alert > degraded >
/// idle (04). Shape (form) is asserted alongside the state so a colour-blind
/// reader is covered.
final class GlyphViewModelTests: XCTestCase {

    func testIdleWhenActiveAndNoAlerts() {
        var s = Canned.statusActive
        s.activeAlerts = 0
        XCTAssertEqual(GlyphViewModel.state(status: s, startingUp: false), .idle)
        XCTAssertEqual(GlyphState.idle.shape, .monochrome)
    }

    func testDegradedWhenPermissionMissing() {
        XCTAssertEqual(GlyphViewModel.state(status: Canned.statusDegraded, startingUp: false), .degraded)
        XCTAssertEqual(GlyphState.degraded.shape, .monochromeWithDot)
    }

    func testAlertWhenActiveAlertsPresent() {
        XCTAssertEqual(GlyphViewModel.state(status: Canned.statusActive, startingUp: false), .alert)
        XCTAssertEqual(GlyphState.alert.shape, .tintedWarning)
    }

    func testStoppedWhenMonitoringStopped() {
        XCTAssertEqual(GlyphViewModel.state(status: Canned.statusStopped, startingUp: false), .stopped)
        XCTAssertEqual(GlyphState.stopped.shape, .hollowOutline)
    }

    // Precedence: attention outranks health — alert wins over degraded.
    func testAlertOutranksDegraded() {
        var s = Canned.statusDegraded
        s.activeAlerts = 2
        XCTAssertEqual(GlyphViewModel.state(status: s, startingUp: false), .alert)
    }

    // Stopped outranks everything, even with alerts queued.
    func testStoppedOutranksAlert() {
        var s = Canned.statusStopped
        s.activeAlerts = 3
        XCTAssertEqual(GlyphViewModel.state(status: s, startingUp: false), .stopped)
    }

    // Startup before first heartbeat shows stopped-hollow, never idle.
    func testStartupShowsStoppedNotIdle() {
        XCTAssertEqual(GlyphViewModel.state(status: nil, startingUp: true), .stopped)
        XCTAssertEqual(GlyphViewModel.state(status: Canned.statusActive, startingUp: true), .stopped)
    }

    // Glyph honesty: when the ONLY missing grant is a system extension this
    // build does not ship, the glyph must NOT show a permanent degraded dot
    // (nothing the user does can clear it). Idle instead.
    func testUnbundledExtensionAloneReadsIdleNotDegraded() {
        let s = StatusDTO(
            monitoring: .degraded, daemonVersion: "1.0.0",
            permissions: .init(inputMonitoring: true, inputMonitoringSensor: "active",
                               esExtension: .inactive),
            scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2,
                           installState: .done, installDetail: nil),
            devicesPresent: 2, activeAlerts: 0, monitoringGaps: [])
        XCTAssertEqual(GlyphViewModel.state(status: s, startingUp: false, extensionBundled: false),
                       .idle, "an uninstallable extension must not nag forever")
        // A build that DOES ship the extension keeps the honest degraded dot.
        XCTAssertEqual(GlyphViewModel.state(status: s, startingUp: false, extensionBundled: true),
                       .degraded)
    }

    // Missing Input Monitoring or scanner still degrade, bundled or not.
    func testOtherMissingGrantsStillDegradeWhenExtensionUnbundled() {
        XCTAssertEqual(GlyphViewModel.state(status: Canned.statusDegraded, startingUp: false,
                                            extensionBundled: false),
                       .degraded, "missing Input Monitoring is actionable and must show")
        var s = Canned.statusDegraded
        s.permissions.inputMonitoring = true
        s.permissions.inputMonitoringSensor = "active"
        s.scanner.available = false
        XCTAssertEqual(GlyphViewModel.state(status: s, startingUp: false, extensionBundled: false),
                       .degraded, "a missing scanner is actionable and must show")
    }

    // VoiceOver hears a plain sentence, never the raw state token (idle/degraded).
    func testAccessibilityPhraseIsHumanNotRawToken() {
        for s in [GlyphState.idle, .degraded, .alert, .stopped] {
            let phrase = s.accessibilityPhrase
            XCTAssertNotEqual(phrase, s.rawValue, "\(s) must not speak its raw token")
            XCTAssertTrue(phrase.lowercased().contains("monitoring") || phrase.lowercased().contains("alert"),
                          "\(s) phrase should read as a sentence")
        }
        XCTAssertEqual(GlyphState.idle.accessibilityPhrase, "monitoring, all clear")
    }
}
