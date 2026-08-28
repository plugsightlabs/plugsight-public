// APISubscriptionTests.swift
//
// Unit F: events.tail / event.appended notifications / events.untail. Appends go
// through the store; the appended event is fanned out to subscribed connections
// ONLY, and only while the subscription is live.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APITestsSubscription: XCTestCase {
    private var server: APIServer!
    private var stateDir: String!
    private var db: TestDB!
    private var device = ""

    override func setUpWithError() throws {
        stateDir = makeTempStateDir()
        db = try makeTestDB(inDir: stateDir)
        let d = try db.event.upsertDevice(from: DeviceDescriptor(
            deviceKey: "d1", vid: 0x046d, pid: 0xc52b, serial: "S-1", vendorName: "Logitech",
            productName: "Keyboard", interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0, usbProtocol: 1)],
            portPath: "0/1"))
        device = d.deviceID
        server = try APIServer(databasePath: db.path, stateDirectory: stateDir, daemonVersion: "1.0.0",
                               capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true))
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    /// Append an event to the store and fan it out exactly as the wired daemon
    /// does (collector appends -> daemon calls apiServer.publish).
    private func appendAndPublish(kind: String, severity: String = "info", deviceID: String? = nil) throws {
        let ev = try db.api.appendEvent(kind: kind, severity: severity, deviceID: deviceID,
                                        actor: "system", summary: "\(kind) happened")
        server.publish(ev)
    }

    func testTailDeliversAppendedEventToSubscriberOnly() throws {
        let subscriber = try authedClient(server)
        defer { subscriber.close() }
        let bystander = try authedClient(server)
        defer { bystander.close() }

        let tail = try XCTUnwrap(subscriber.call(id: 1, method: "events.tail").rpcResult)
        XCTAssertNotNil(tail["subscriptionId"] as? String)

        try appendAndPublish(kind: "device.attached", deviceID: device)

        // The subscriber receives an event.appended NOTIFICATION (no id).
        let note = try XCTUnwrap(subscriber.readLine(), "subscriber should receive event.appended")
        XCTAssertEqual(note["method"] as? String, "event.appended")
        XCTAssertNil(note["id"])
        let params = try XCTUnwrap(note["params"] as? [String: Any])
        XCTAssertEqual(params["kind"] as? String, "device.attached")
        XCTAssertNotNil(params["eventId"] as? String)

        // The bystander (never subscribed) receives nothing.
        XCTAssertNil(bystander.readLine(), "bystander must not receive the notification")
    }

    func testUntailStopsDelivery() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let tail = try XCTUnwrap(c.call(id: 1, method: "events.tail").rpcResult)
        let subId = try XCTUnwrap(tail["subscriptionId"] as? String)

        // First append arrives.
        try appendAndPublish(kind: "device.attached", deviceID: device)
        let first = try XCTUnwrap(c.readLine())
        XCTAssertEqual(first["method"] as? String, "event.appended")

        // Untail, then a second append must NOT arrive.
        let stop = try XCTUnwrap(c.call(id: 2, method: "events.untail", params: ["subscriptionId": subId]).rpcResult)
        XCTAssertEqual(stop["ok"] as? Bool, true)

        try appendAndPublish(kind: "device.detached", deviceID: device)
        XCTAssertNil(c.readLine(), "no notifications after untail")
    }

    func testTailFilterOnlyMatchingKinds() throws {
        let c = try authedClient(server)
        defer { c.close() }
        _ = try XCTUnwrap(c.call(id: 1, method: "events.tail",
            params: ["filter": ["kinds": ["trust.changed"]]]).rpcResult)

        // A non-matching kind is not delivered.
        try appendAndPublish(kind: "device.attached", deviceID: device)
        XCTAssertNil(c.readLine(), "device.attached should not match a trust.changed filter")

        // A matching kind is delivered.
        try appendAndPublish(kind: "trust.changed", deviceID: device)
        let note = try XCTUnwrap(c.readLine())
        XCTAssertEqual((note["params"] as? [String: Any])?["kind"] as? String, "trust.changed")
    }

    func testTrustSetFansOutThroughTheApiPath() throws {
        // A subscriber sees an event produced by another connection's mutation.
        let subscriber = try authedClient(server)
        defer { subscriber.close() }
        _ = try XCTUnwrap(subscriber.call(id: 1, method: "events.tail").rpcResult)

        let mutator = try authedClient(server, name: "ui", kind: "ui")
        defer { mutator.close() }
        _ = try mutator.call(id: 1, method: "trust.set", params: ["deviceId": device, "tier": "trusted"])

        let note = try XCTUnwrap(subscriber.readLine(), "subscriber should see the trust.changed from the other client")
        XCTAssertEqual((note["params"] as? [String: Any])?["kind"] as? String, "trust.changed")
    }
}
