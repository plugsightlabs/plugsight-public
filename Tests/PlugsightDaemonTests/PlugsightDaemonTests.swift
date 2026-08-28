import XCTest
@testable import PlugsightDaemon
import PlugsightCore
import PlugsightTestKit

/// Placeholder so the PlugsightDaemonTests target has a source and builds against
/// PlugsightDaemon + PlugsightTestKit. Real daemon behavior is tested in later nodes.
final class PlugsightDaemonTests: XCTestCase {
    func testTestKitIsReachableFromDaemonTests() async throws {
        let source: any DeviceEventSource = FakeDeviceEventSource(events: [])
        try source.start()
        var count = 0
        for await _ in source.events { count += 1 }
        source.stop()
        XCTAssertEqual(count, 0)
    }
}
