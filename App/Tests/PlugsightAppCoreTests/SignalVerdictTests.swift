// SignalVerdictTests.swift  (Wave 1b)
//
// The signal verdict color mapping: the daemon emits "normal" / "suspicious"
// (DaemonCore.signalsJSON), while older canned fixtures used "clear". The view
// colored green ONLY on the literal "clear", so every real daemon verdict
// rendered orange. Both words must read as the clear/green case.

import XCTest
@testable import PlugsightAppCore

final class SignalVerdictTests: XCTestCase {

    func testDaemonNormalVerdictIsClear() {
        XCTAssertTrue(DeviceInspectorView.verdictIsClear("normal"),
                      "the daemon's real clear word is \"normal\"")
    }

    func testLegacyClearVerdictStaysClear() {
        XCTAssertTrue(DeviceInspectorView.verdictIsClear("clear"))
    }

    func testSuspiciousAndUnknownVerdictsAreNotClear() {
        XCTAssertFalse(DeviceInspectorView.verdictIsClear("suspicious"))
        XCTAssertFalse(DeviceInspectorView.verdictIsClear(""))
        XCTAssertFalse(DeviceInspectorView.verdictIsClear("weird"))
    }
}
