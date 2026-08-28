import XCTest
@testable import PlugsightAppCore

/// Transport-level checks that need no daemon. Full response-shape parity is an
/// integration concern (a running daemon), out of scope for the unit gate.
final class LiveAPIClientTests: XCTestCase {

    // 9b: no token/socket present → daemon_unreachable with the literal fix.
    func testMissingDaemonSurfacesDaemonUnreachable() async {
        let tmp = NSTemporaryDirectory() + "plugsight-live-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let client = LiveAPIClient(stateDirectory: tmp)
        do {
            _ = try await client.getStatus()
            XCTFail("expected daemon_unreachable")
        } catch let e as APIError {
            XCTAssertEqual(e.kind, .daemonUnreachable)
            XCTAssertTrue(e.message.contains("Start Plugsight"))
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    // The canonical error message doubles as the recovery a human can follow.
    func testDaemonUnreachableMessageIsSelfSufficient() {
        XCTAssertTrue(APIError.daemonUnreachable.message.contains("Applications"))
    }
}
