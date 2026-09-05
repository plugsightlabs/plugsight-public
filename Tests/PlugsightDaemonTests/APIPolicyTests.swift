// APIPolicyTests.swift
//
// Unit E: policy.get / policy.set — canonical v1 keys + defaults, shallow-merge
// per top-level key, unknown-key rejection naming the key, and the confirm:true
// gate on the owner-gated holdUntilScanned key.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APITestsPolicy: XCTestCase {
    private var server: APIServer!
    private var stateDir: String!
    private var db: TestDB!

    override func setUpWithError() throws {
        stateDir = makeTempStateDir()
        db = try makeTestDB(inDir: stateDir)
        server = try APIServer(databasePath: db.path, stateDirectory: stateDir, daemonVersion: "1.0.0",
                               capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true))
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    func testPolicyGetReturnsDefaults() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "policy.get").rpcResult)
        XCTAssertEqual(r["scanOnMount"] as? Bool, true)
        XCTAssertEqual(r["quarantine"] as? Bool, true)
        XCTAssertEqual(r["holdUntilScanned"] as? Bool, false)
        XCTAssertEqual(r["scanTimeoutMinutes"] as? Int, 15)
        XCTAssertEqual(r["definitionsWarnDays"] as? Int, 7)
        XCTAssertEqual(r["retentionDays"] as? Int, 365)
        XCTAssertNil(r["clamdSocketPath"] as? String)
    }

    func testPolicySetShallowMergesAndReturnsFull() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "policy.set",
            params: ["scanOnMount": true, "scanTimeoutMinutes": 30, "clamdSocketPath": "/tmp/clamd.sock"]).rpcResult)
        // Changed keys take the new value; untouched keys keep defaults.
        XCTAssertEqual(r["scanOnMount"] as? Bool, true)
        XCTAssertEqual(r["scanTimeoutMinutes"] as? Int, 30)
        XCTAssertEqual(r["clamdSocketPath"] as? String, "/tmp/clamd.sock")
        XCTAssertEqual(r["quarantine"] as? Bool, true)     // untouched default
        XCTAssertEqual(r["retentionDays"] as? Int, 365)    // untouched default

        // Persisted: a fresh get reflects the merge.
        let again = try XCTUnwrap(c.call(id: 2, method: "policy.get").rpcResult)
        XCTAssertEqual(again["scanOnMount"] as? Bool, true)
        XCTAssertEqual(again["scanTimeoutMinutes"] as? Int, 30)
    }

    func testPolicySetUnknownKeyRejectedByName() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "policy.set", params: ["turboMode": true])
        let err = try XCTUnwrap(resp.rpcError)
        XCTAssertEqual((err["data"] as? [String: Any])?["kind"] as? String, "invalid_params")
        XCTAssertTrue((err["message"] as? String ?? "").contains("turboMode"), "message names the offending key")
    }

    func testHoldUntilScannedRequiresConfirm() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "policy.set", params: ["holdUntilScanned": true])
        let err = try XCTUnwrap(resp.rpcError)
        XCTAssertEqual((err["data"] as? [String: Any])?["kind"] as? String, "invalid_params")
        XCTAssertTrue((err["message"] as? String ?? "").lowercased().contains("confirm"))
        // Unchanged in the store.
        let get = try XCTUnwrap(c.call(id: 2, method: "policy.get").rpcResult)
        XCTAssertEqual(get["holdUntilScanned"] as? Bool, false)
    }

    func testHoldUntilScannedWithConfirmSucceeds() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "policy.set",
            params: ["holdUntilScanned": true, "confirm": true]).rpcResult)
        XCTAssertEqual(r["holdUntilScanned"] as? Bool, true)
    }

    func testPolicySetWrongTypeIsInvalidParams() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "policy.set", params: ["scanTimeoutMinutes": "soon"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "invalid_params")
    }

    // MARK: - Notification keys (04 notification model, D-notify)

    func testPolicyDefaultsIncludeNotificationKeys() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "policy.get").rpcResult)
        XCTAssertEqual(r["notifyUnsafe"] as? Bool, true, "the core promise defaults on")
        XCTAssertEqual(r["notifyNewDevice"] as? Bool, false)
        // The retired key is still SERVED for old readers.
        XCTAssertEqual(r["notificationThreshold"] as? String, "warning")
    }

    func testNotificationKeysRoundTrip() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "policy.set",
            params: ["notifyUnsafe": false, "notifyNewDevice": true]).rpcResult)
        XCTAssertEqual(r["notifyUnsafe"] as? Bool, false)
        XCTAssertEqual(r["notifyNewDevice"] as? Bool, true)
        let again = try XCTUnwrap(c.call(id: 2, method: "policy.get").rpcResult)
        XCTAssertEqual(again["notifyUnsafe"] as? Bool, false)
        XCTAssertEqual(again["notifyNewDevice"] as? Bool, true)
    }

    func testNotificationKeysRequireBooleans() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "policy.set", params: ["notifyUnsafe": "yes"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "invalid_params")
    }

    func testNotificationThresholdWritesAreRejectedNamingTheNewKeys() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "policy.set", params: ["notificationThreshold": "critical"])
        let err = try XCTUnwrap(resp.rpcError)
        XCTAssertEqual((err["data"] as? [String: Any])?["kind"] as? String, "invalid_params")
        let message = err["message"] as? String ?? ""
        XCTAssertTrue(message.contains("notifyUnsafe"), "the error names the replacement key")
        XCTAssertTrue(message.contains("notifyNewDevice"), "the error names the replacement key")
    }

    func testLegacyThresholdWarningMigratesToNotifyUnsafeOnly() throws {
        // A pre-D-notify install stored a threshold. Its first policy read maps
        // it: any threshold -> notifyUnsafe on; only "everything" also wanted
        // new-device notifications.
        try db.api.setPolicyKey("notificationThreshold", valueJSON: "\"warning\"", actor: "ui")
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "policy.get").rpcResult)
        XCTAssertEqual(r["notifyUnsafe"] as? Bool, true)
        XCTAssertEqual(r["notifyNewDevice"] as? Bool, false)
        XCTAssertEqual(r["notificationThreshold"] as? String, "warning", "old readers still see it")
        // One-time and persisted: the new keys now exist as their own rows.
        let raw = try db.api.policyRaw()
        XCTAssertNotNil(raw["notifyUnsafe"])
        XCTAssertNotNil(raw["notifyNewDevice"])
    }

    func testLegacyThresholdEverythingMigratesToBothKeys() throws {
        try db.api.setPolicyKey("notificationThreshold", valueJSON: "\"everything\"", actor: "ui")
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "policy.get").rpcResult)
        XCTAssertEqual(r["notifyUnsafe"] as? Bool, true)
        XCTAssertEqual(r["notifyNewDevice"] as? Bool, true)
    }

    func testMigrationNeverOverridesAnExplicitChoice() throws {
        // The user already chose notifyUnsafe:false; a lingering legacy row
        // must not flip it back on.
        try db.api.setPolicyKey("notificationThreshold", valueJSON: "\"everything\"", actor: "ui")
        try db.api.setPolicyKey("notifyUnsafe", valueJSON: "false", actor: "ui")
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "policy.get").rpcResult)
        XCTAssertEqual(r["notifyUnsafe"] as? Bool, false)
        XCTAssertEqual(r["notifyNewDevice"] as? Bool, false)
    }

    // An out-of-Int64-range double must be rejected as invalid_params and leave
    // the daemon running, not trap on the Int(Double) conversion.
    func testPolicySetOutOfRangeNumberIsInvalidParams() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "policy.set", params: ["scanTimeoutMinutes": 1e19])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "invalid_params")
        // The daemon survives: a follow-up call still gets a response.
        let get = try XCTUnwrap(c.call(id: 2, method: "policy.get").rpcResult)
        XCTAssertEqual(get["scanTimeoutMinutes"] as? Int, 15)
    }
}
