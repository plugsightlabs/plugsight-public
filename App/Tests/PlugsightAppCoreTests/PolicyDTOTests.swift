import XCTest
@testable import PlugsightAppCore

/// Wave 2: PolicyDTO carries the two new notification keys, decode-forgiving.
/// The daemon gains `notifyUnsafe` / `notifyNewDevice` on a parallel branch, so
/// the app must decode and behave correctly with or without them on the wire.
final class PolicyDTOTests: XCTestCase {

    func testDecodesWithoutNotificationKeys() throws {
        // An older daemon: only the pre-Wave-2 keys. The new fields decode nil.
        let json = """
        {"scanOnMount": true, "holdUntilScanned": false, "notificationThreshold": "warning"}
        """
        let policy = try JSONDecoder().decode(PolicyDTO.self, from: Data(json.utf8))
        XCTAssertNil(policy.notifyUnsafe, "absent key decodes to nil, never a fabricated default")
        XCTAssertNil(policy.notifyNewDevice)
        XCTAssertTrue(policy.scanOnMount)
    }

    func testDecodesWithNotificationKeys() throws {
        let json = """
        {"scanOnMount": true, "holdUntilScanned": false, "notificationThreshold": "warning",
         "notifyUnsafe": false, "notifyNewDevice": true}
        """
        let policy = try JSONDecoder().decode(PolicyDTO.self, from: Data(json.utf8))
        XCTAssertEqual(policy.notifyUnsafe, false)
        XCTAssertEqual(policy.notifyNewDevice, true)
    }

    func testSetPolicyPassesNotificationKeysThrough() async throws {
        let api = FakeAPIClient()
        _ = try await api.setPolicy(scanOnMount: nil, holdNewDrives: nil, notificationThreshold: nil,
                                    notifyUnsafe: true, notifyNewDevice: false, confirm: true)
        XCTAssertEqual(api.lastPolicy?.notifyUnsafe, true)
        XCTAssertEqual(api.lastPolicy?.notifyNewDevice, false)
        XCTAssertEqual(api.lastPolicy?.confirm, true)
    }

    func testLegacySetPolicyOverloadSendsNilNotificationKeys() async throws {
        // The pre-Wave-2 call sites keep compiling and leave the new keys untouched.
        let api = FakeAPIClient()
        _ = try await api.setPolicy(scanOnMount: false, holdNewDrives: nil,
                                    notificationThreshold: nil, confirm: true)
        XCTAssertEqual(api.lastPolicy?.scanOnMount, false)
        XCTAssertNil(api.lastPolicy?.notifyUnsafe ?? nil)
        XCTAssertNil(api.lastPolicy?.notifyNewDevice ?? nil)
    }
}
