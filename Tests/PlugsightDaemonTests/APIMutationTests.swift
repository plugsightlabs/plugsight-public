// APIMutationTests.swift
//
// Unit C: score.get, alerts.list/ack, trust.set — including actor stamping on
// mutations, the conflict-on-double-ack rule, and error shapes.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APITestsMutation: XCTestCase {
    private var server: APIServer!
    private var stateDir: String!
    private var db: TestDB!
    private var device = ""

    override func setUpWithError() throws {
        stateDir = makeTempStateDir()
        db = try makeTestDB(inDir: stateDir)
        try seed()
        server = try APIServer(
            databasePath: db.path, stateDirectory: stateDir, daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true))
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    private func seed() throws {
        let d = try db.event.upsertDevice(from: DeviceDescriptor(
            deviceKey: "d1", vid: 0x046d, pid: 0xc52b, serial: "S-1",
            vendorName: "Logitech", productName: "Bad Keyboard",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0, usbProtocol: 1)],
            portPath: "0/1"))
        device = d.deviceID
        try db.api.seedScore(deviceID: device, score: 78, confidence: "medium",
            signals: #"[{"id":"plug_to_type_latency","observed":"410ms","verdict":"suspicious","weight":0.35}]"#)
        try db.api.seedAlert(id: "alr_c1", deviceID: device, rule: "R1", severity: "critical",
            state: "active", summary: "Charger that is also a keyboard.", why: "R1 mismatch.")
        try db.api.seedAlert(id: "alr_c2", deviceID: device, rule: "behavioral_score", severity: "warning",
            state: "resolved", summary: "Score settled.", why: "Score fell below threshold.")
    }

    // MARK: - score.get

    func testScoreGetReturnsBreakdownAndCaveat() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "score.get", params: ["deviceId": device]).rpcResult)
        XCTAssertEqual(r["score"] as? Int, 78)
        XCTAssertEqual(r["confidence"] as? String, "medium")
        let signals = try XCTUnwrap(r["signals"] as? [[String: Any]])
        XCTAssertEqual(signals.first?["id"] as? String, "plug_to_type_latency")
        // Charter item: every score payload carries the caveat.
        XCTAssertFalse((r["caveat"] as? String ?? "").isEmpty)
    }

    func testScoreGetUnknownDeviceNotFound() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "score.get", params: ["deviceId": "dev_nope"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "not_found")
    }

    // MARK: - alerts.list

    func testAlertsListAndStateFilter() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let all = try XCTUnwrap(c.call(id: 1, method: "alerts.list").rpcResult)
        XCTAssertEqual((all["alerts"] as? [[String: Any]])?.count, 2)
        let active = try XCTUnwrap(c.call(id: 2, method: "alerts.list", params: ["filter": ["state": "active"]]).rpcResult)
        let a = try XCTUnwrap(active["alerts"] as? [[String: Any]])
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0]["alertId"] as? String, "alr_c1")
        XCTAssertEqual(a[0]["severity"] as? String, "critical")
    }

    // MARK: - alerts.ack (actor stamping + conflict)

    func testAlertsAckStampsActorAndAppendsEvent() throws {
        let c = try authedClient(server, name: "claude-code", kind: "mcp")
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "alerts.ack",
            params: ["alertId": "alr_c1", "comment": "looks handled"]).rpcResult)
        let alert = try XCTUnwrap(r["alert"] as? [String: Any])
        XCTAssertEqual(alert["state"] as? String, "acknowledged")
        XCTAssertEqual(alert["ackedBy"] as? String, "mcp:claude-code")
        XCTAssertEqual(alert["ackComment"] as? String, "looks handled")
        let event = try XCTUnwrap(r["event"] as? [String: Any])
        XCTAssertEqual(event["kind"] as? String, "alert.acknowledged")
        XCTAssertEqual(event["actor"] as? String, "mcp:claude-code")
    }

    func testAlertsAckDoubleIsConflict() throws {
        let c = try authedClient(server)
        defer { c.close() }
        _ = try c.call(id: 1, method: "alerts.ack", params: ["alertId": "alr_c1"])
        let again = try c.call(id: 2, method: "alerts.ack", params: ["alertId": "alr_c1"])
        XCTAssertEqual((again.rpcError?["data"] as? [String: Any])?["kind"] as? String, "conflict")
    }

    func testAlertsAckResolvedIsConflict() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "alerts.ack", params: ["alertId": "alr_c2"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "conflict")
    }

    func testAlertsAckUnknownNotFound() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "alerts.ack", params: ["alertId": "alr_nope"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "not_found")
    }

    // MARK: - trust.set (actor stamping + trust.changed event)

    func testTrustSetUpdatesDeviceAndEmitsEvent() throws {
        let c = try authedClient(server, name: "menubar", kind: "ui")
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "trust.set",
            params: ["deviceId": device, "tier": "trusted", "note": "my keyboard"]).rpcResult)
        let dev = try XCTUnwrap(r["device"] as? [String: Any])
        XCTAssertEqual(dev["trust"] as? String, "trusted")
        XCTAssertEqual(dev["trustNote"] as? String, "my keyboard")
        XCTAssertEqual(dev["trustSetBy"] as? String, "ui")
        let event = try XCTUnwrap(r["event"] as? [String: Any])
        XCTAssertEqual(event["kind"] as? String, "trust.changed")
        XCTAssertEqual(event["actor"] as? String, "ui")
        // Forgeability caveat rides on every trust mutation.
        XCTAssertFalse((r["caveat"] as? String ?? "").isEmpty)

        // The trust.changed detail records old -> new tier.
        let full = try XCTUnwrap(c.call(id: 2, method: "events.get",
            params: ["eventId": event["eventId"] as! String]).rpcResult)
        let context = try XCTUnwrap(full["context"] as? [String: Any])
        let detail = try XCTUnwrap(context["detail"] as? [String: Any])
        XCTAssertEqual(detail["from"] as? String, "none")
        XCTAssertEqual(detail["to"] as? String, "trusted")
    }

    /// C2 regression: the per-change trust note must survive into `trustHistory`.
    /// Before the fix the `trust.changed` detail omitted `note`, so every
    /// `TrustHistoryEntry.note` (and MCP `oTrustHistory.note`) was always nil even
    /// though a note was supplied.
    func testTrustHistorySurfacesTheNotePerChange() throws {
        let c = try authedClient(server, name: "menubar", kind: "ui")
        defer { c.close() }

        // A change WITH a note, and a later change with NO note.
        _ = try XCTUnwrap(c.call(id: 1, method: "trust.set",
            params: ["deviceId": device, "tier": "trusted", "note": "my keyboard"]).rpcResult)
        _ = try XCTUnwrap(c.call(id: 2, method: "trust.set",
            params: ["deviceId": device, "tier": "muted"]).rpcResult)

        let dev = try XCTUnwrap(c.call(id: 3, method: "devices.get",
            params: ["deviceId": device]).rpcResult)
        let history = try XCTUnwrap(dev["trustHistory"] as? [[String: Any]])
        XCTAssertEqual(history.count, 2, "both trust changes are in the history")

        // Newest first: the no-note change carries no note (nil, not a crash);
        // the earlier change surfaces exactly the supplied note.
        XCTAssertNil(history[0]["note"], "a change with no note yields a nil note")
        XCTAssertEqual(history[1]["note"] as? String, "my keyboard",
                       "the supplied note is surfaced per change (was always nil before the fix)")
    }

    func testTrustSetUnknownDeviceNotFound() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "trust.set", params: ["deviceId": "dev_nope", "tier": "muted"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "not_found")
    }

    func testTrustSetInvalidTierIsInvalidParams() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "trust.set", params: ["deviceId": device, "tier": "banana"])
        let err = resp.rpcError
        XCTAssertEqual((err?["data"] as? [String: Any])?["kind"] as? String, "invalid_params")
        XCTAssertTrue((err?["message"] as? String ?? "").contains("tier"), "message names the offending key")
    }
}
