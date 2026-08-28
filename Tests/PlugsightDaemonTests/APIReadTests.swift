// APIReadTests.swift
//
// Unit B: the read methods against a seeded store over a real socket —
// status.get, devices.list, devices.get, timeline.list (with filters), events.get.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APITestsRead: XCTestCase {
    private var server: APIServer!
    private var stateDir: String!
    private var db: TestDB!
    private var kbDevice = ""
    private var storageDevice = ""

    override func setUpWithError() throws {
        stateDir = makeTempStateDir()
        db = try makeTestDB(inDir: stateDir)
        try seed()
        server = try APIServer(
            databasePath: db.path,
            stateDirectory: stateDir,
            daemonVersion: "2.0.0",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: true)
        )
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    private func seed() throws {
        // A composite keyboard device and a storage device.
        let kb = try db.event.upsertDevice(from: DeviceDescriptor(
            deviceKey: "k1", vid: 0x046d, pid: 0xc52b, serial: "KB-SERIAL-123",
            vendorName: "Logitech", productName: "Logitech USB Receiver",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0, usbProtocol: 1)],
            portPath: "0/1"))
        kbDevice = kb.deviceID
        let st = try db.event.upsertDevice(from: DeviceDescriptor(
            deviceKey: "s1", vid: 0x0781, pid: 0x5567, serial: "SD-SERIAL-999",
            vendorName: "SanDisk", productName: "SanDisk Ultra",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 6, usbProtocol: 0x50)],
            portPath: "0/2"))
        storageDevice = st.deviceID

        _ = try db.event.appendEvent(kind: "device.attached", severity: "info", deviceID: kbDevice,
                                     actor: "system", summary: "Logitech USB Receiver plugged in. Presents as: keyboard.")
        _ = try db.event.appendEvent(kind: "hid.typing_burst", severity: "warning", deviceID: kbDevice,
                                     actor: "system", summary: "Typed 47 keys in 1.1 seconds.",
                                     detail: #"{"v":1,"keys":47,"ms":1100}"#)
        _ = try db.event.appendEvent(kind: "device.attached", severity: "info", deviceID: storageDevice,
                                     actor: "system", summary: "SanDisk Ultra plugged in. Presents as: storage.")
        try db.api.seedAlert(id: "alr_read1", deviceID: kbDevice, rule: "R1", severity: "critical",
                             state: "active", summary: "Presented as a charger, but also a keyboard.",
                             why: "R1 mismatch: charger + HID keyboard on one device.")
    }

    // MARK: - status.get

    func testStatusGetReportsCountsAndDegradedMode() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let result = try XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)
        XCTAssertEqual(result["devicesPresent"] as? Int, 2)
        XCTAssertEqual(result["activeAlerts"] as? Int, 1)
        XCTAssertGreaterThanOrEqual(result["eventCount"] as? Int ?? 0, 3)
        XCTAssertEqual(result["monitoring"] as? String, "degraded")  // ES capability off
        XCTAssertEqual(result["daemonVersion"] as? String, "2.0.0")
        let scanner = try XCTUnwrap(result["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["available"] as? Bool, true)
        let perms = try XCTUnwrap(result["permissions"] as? [String: Any])
        XCTAssertEqual(perms["esExtension"] as? String, "inactive")
    }

    // MARK: - devices.list

    func testDevicesListReturnsSummaries() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let result = try XCTUnwrap(c.call(id: 1, method: "devices.list").rpcResult)
        let devices = try XCTUnwrap(result["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 2)
        let kb = try XCTUnwrap(devices.first { ($0["deviceId"] as? String) == kbDevice })
        XCTAssertEqual(kb["name"] as? String, "Logitech USB Receiver")
        XCTAssertEqual(kb["vidPid"] as? String, "046d:c52b")
        XCTAssertEqual(kb["present"] as? Bool, true)
        XCTAssertEqual(kb["trust"] as? String, "none")
        XCTAssertEqual(kb["interfaceClasses"] as? [String], ["keyboard"])
        XCTAssertEqual(kb["activeAlerts"] as? Int, 1)
    }

    func testDevicesListPresentFilter() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let result = try XCTUnwrap(c.call(id: 1, method: "devices.list", params: ["filter": ["present": true]]).rpcResult)
        XCTAssertEqual((result["devices"] as? [[String: Any]])?.count, 2)
        let none = try XCTUnwrap(c.call(id: 2, method: "devices.list", params: ["filter": ["present": false]]).rpcResult)
        XCTAssertEqual((none["devices"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - devices.get

    func testDevicesGetFullRecord() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let result = try XCTUnwrap(c.call(id: 1, method: "devices.get", params: ["deviceId": kbDevice]).rpcResult)
        XCTAssertEqual(result["deviceId"] as? String, kbDevice)
        XCTAssertEqual(result["identityBasis"] as? String, "serial")
        XCTAssertEqual(result["eventCount"] as? Int, 2)
        let ifaces = try XCTUnwrap(result["interfaces"] as? [[String: Any]])
        XCTAssertEqual(ifaces.count, 1)
        XCTAssertEqual(ifaces[0]["role"] as? String, "keyboard")
        // Interface rows carry the raw codes as class/subclass/protocol (03/06).
        XCTAssertEqual(ifaces[0]["class"] as? Int, 3)
        XCTAssertEqual(ifaces[0]["seq"] as? Int, 0)
        // Derived fields the UI decodes: trust history, isStorage.
        XCTAssertNotNil(result["trustHistory"] as? [[String: Any]])
        XCTAssertEqual(result["isStorage"] as? Bool, false)
    }

    func testDevicesGetUnknownIsNotFound() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "devices.get", params: ["deviceId": "dev_nope"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "not_found")
    }

    // MARK: - timeline.list

    func testTimelineNewestFirstAndDeviceFilter() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let all = try XCTUnwrap(c.call(id: 1, method: "timeline.list").rpcResult)
        let events = try XCTUnwrap(all["events"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(events.count, 3)
        // Newest first: the ULID ids strictly descend.
        let ids = events.compactMap { $0["eventId"] as? String }
        XCTAssertEqual(ids, ids.sorted(by: >))

        let filtered = try XCTUnwrap(c.call(id: 2, method: "timeline.list",
            params: ["filter": ["deviceId": storageDevice]]).rpcResult)
        let se = try XCTUnwrap(filtered["events"] as? [[String: Any]])
        XCTAssertEqual(se.count, 1)
        XCTAssertEqual(se[0]["deviceId"] as? String, storageDevice)
    }

    func testTimelineKindAndSeverityFilter() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "timeline.list",
            params: ["filter": ["kinds": ["hid.typing_burst"], "severity": "warning"]]).rpcResult)
        let events = try XCTUnwrap(r["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["kind"] as? String, "hid.typing_burst")
    }

    func testTimelineLimitAndCursor() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let page1 = try XCTUnwrap(c.call(id: 1, method: "timeline.list", params: ["limit": 2]).rpcResult)
        let e1 = try XCTUnwrap(page1["events"] as? [[String: Any]])
        XCTAssertEqual(e1.count, 2)
        let cursor = try XCTUnwrap(page1["nextCursor"] as? String)
        let page2 = try XCTUnwrap(c.call(id: 2, method: "timeline.list", params: ["limit": 2, "cursor": cursor]).rpcResult)
        let e2 = try XCTUnwrap(page2["events"] as? [[String: Any]])
        // No overlap between pages.
        let ids1 = Set(e1.compactMap { $0["eventId"] as? String })
        let ids2 = Set(e2.compactMap { $0["eventId"] as? String })
        XCTAssertTrue(ids1.isDisjoint(with: ids2))
    }

    // MARK: - events.get

    func testEventsGetReturnsDetailPayload() throws {
        let c = try authedClient(server)
        defer { c.close() }
        // Find the typing-burst event id via the timeline.
        let tl = try XCTUnwrap(c.call(id: 1, method: "timeline.list",
            params: ["filter": ["kinds": ["hid.typing_burst"]]]).rpcResult)
        let evId = try XCTUnwrap((tl["events"] as? [[String: Any]])?.first?["eventId"] as? String)

        let ev = try XCTUnwrap(c.call(id: 2, method: "events.get", params: ["eventId": evId]).rpcResult)
        // explain_event nests the event, and carries why + context + suggestedActions.
        let event = try XCTUnwrap(ev["event"] as? [String: Any])
        XCTAssertEqual(event["eventId"] as? String, evId)
        XCTAssertEqual(event["kind"] as? String, "hid.typing_burst")
        XCTAssertFalse((ev["why"] as? String ?? "").isEmpty)
        let context = try XCTUnwrap(ev["context"] as? [String: Any])
        let detail = try XCTUnwrap(context["detail"] as? [String: Any])
        XCTAssertEqual(detail["keys"] as? Int, 47)
        XCTAssertEqual(detail["v"] as? Int, 1)
        XCTAssertFalse((ev["suggestedActions"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testEventsGetUnknownIsNotFound() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "events.get", params: ["eventId": "evt_nope"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "not_found")
    }
}
