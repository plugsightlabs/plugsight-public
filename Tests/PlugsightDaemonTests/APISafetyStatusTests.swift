// APISafetyStatusTests.swift
//
// Integration tests for the derived per-device SafetyStatus over the wire
// (docs/spec/04 verdict model, S2e): seed stores that produce each color and
// assert `safetyStatus` (status + reasons with id/sentence/action) rides on
// devices.list AND devices.get, with the same derivation on both.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APISafetyStatusTests: XCTestCase {
    private var stateDir: String!
    private var db: TestDB!
    private var servers: [APIServer] = []

    override func setUpWithError() throws {
        stateDir = makeTempStateDir()
        db = try makeTestDB(inDir: stateDir)
    }

    override func tearDownWithError() throws {
        for s in servers { s.stop() }
        servers = []
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    /// Start a server over the shared test DB with controllable capabilities.
    private func makeServer(
        inputMonitoring: Bool = true, clamav: Bool = true,
        definitionsAgeDays: Int? = nil,
        inputMonitoringResolver: (@Sendable () -> Bool)? = nil
    ) throws -> APIServer {
        let server = APIServer(
            store: db.event, stateDirectory: stateDir, daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: inputMonitoring, endpointSecurity: true, clamav: clamav),
            definitionsAgeResolver: definitionsAgeDays.map { age in { age } },
            inputMonitoringResolver: inputMonitoringResolver)
        try server.start()
        servers.append(server)
        return server
    }

    // MARK: - Seeding helpers

    @discardableResult
    private func seedStorageDevice(key: String = "s1", serial: String = "SD-1") throws -> String {
        try db.event.upsertDevice(from: DeviceDescriptor(
            deviceKey: key, vid: 0x0781, pid: 0x5567, serial: serial,
            vendorName: "SanDisk", productName: "SanDisk Ultra",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 6, usbProtocol: 0x50)],
            portPath: "0/2")).deviceID
    }

    @discardableResult
    private func seedKeyboardDevice(key: String = "k1", serial: String = "KB-1") throws -> String {
        try db.event.upsertDevice(from: DeviceDescriptor(
            deviceKey: key, vid: 0x046d, pid: 0xc52b, serial: serial,
            vendorName: "Logitech", productName: "Logitech Keyboard",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 1, usbProtocol: 1)],
            portPath: "0/1")).deviceID
    }

    private func seedScan(deviceID: String, state: String) throws {
        let scan = try db.api.insertScan(deviceID: deviceID, volumePath: "/Volumes/T", engine: "clamdscan", startedBy: "ui")
        if state != "running" {
            try db.api.setScanState(id: scan.id, state: state, filesScanned: 10, finishedAt: Date())
        }
    }

    // MARK: - Wire helpers

    private func safetyStatus(fromList c: UDSTestClient, deviceID: String, id: Int) throws -> [String: Any] {
        let r = try XCTUnwrap(c.call(id: id, method: "devices.list").rpcResult)
        let devices = try XCTUnwrap(r["devices"] as? [[String: Any]])
        let row = try XCTUnwrap(devices.first { ($0["deviceId"] as? String) == deviceID },
                                "device \(deviceID) in devices.list")
        return try XCTUnwrap(row["safetyStatus"] as? [String: Any],
                             "devices.list row carries safetyStatus")
    }

    private func safetyStatus(fromGet c: UDSTestClient, deviceID: String, id: Int) throws -> [String: Any] {
        let r = try XCTUnwrap(c.call(id: id, method: "devices.get", params: ["deviceId": deviceID]).rpcResult)
        return try XCTUnwrap(r["safetyStatus"] as? [String: Any],
                             "devices.get carries safetyStatus")
    }

    private func reasons(_ status: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(status["reasons"] as? [[String: Any]])
    }

    // MARK: - green

    func testCleanScannedDriveIsGreenOverTheWire() throws {
        let dev = try seedStorageDevice()
        try seedScan(deviceID: dev, state: "clean")
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "green")
        let rs = try reasons(s)
        XCTAssertEqual(rs.first?["id"] as? String, "all.clear")
        XCTAssertEqual(rs.first?["action"] as? String, "none")
        XCTAssertFalse((rs.first?["sentence"] as? String ?? "").isEmpty)

        // devices.get tells the same story.
        let g = try safetyStatus(fromGet: c, deviceID: dev, id: 2)
        XCTAssertEqual(g["status"] as? String, "green")
    }

    func testCleanDriveMidRescanStaysGreen() throws {
        let dev = try seedStorageDevice()
        try seedScan(deviceID: dev, state: "clean")
        try seedScan(deviceID: dev, state: "running")   // rescan in flight
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let r = try XCTUnwrap(c.call(id: 1, method: "devices.list").rpcResult)
        let row = try XCTUnwrap((r["devices"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["scanning"] as? Bool, true)
        XCTAssertEqual((row["safetyStatus"] as? [String: Any])?["status"] as? String, "green",
                       "a rescan in flight does not erase the standing clean verdict")
    }

    // MARK: - red

    func testInfectedScanIsRedOverTheWire() throws {
        let dev = try seedStorageDevice()
        try seedScan(deviceID: dev, state: "infected")
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let s = try safetyStatus(fromGet: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "red")
        let first = try XCTUnwrap(try reasons(s).first)
        XCTAssertEqual(first["id"] as? String, "scan.infected")
        XCTAssertEqual(first["action"] as? String, "reviewQuarantine")
    }

    func testActiveCriticalAlertIsRedOverTheWire() throws {
        let dev = try seedKeyboardDevice()
        try db.api.seedAlert(id: "alr_c1", deviceID: dev, rule: "R1", severity: "critical",
                             state: "active", summary: "Charger that also types.", why: "R1")
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "red")
        XCTAssertEqual(try reasons(s).first?["id"] as? String, "alert.critical")
    }

    func testAcknowledgedCriticalAlertDoesNotStayRed() throws {
        let dev = try seedKeyboardDevice()
        try db.api.seedAlert(id: "alr_c2", deviceID: dev, rule: "R1", severity: "critical",
                             state: "acknowledged", summary: "Handled.", why: "R1")
        let c = try authedClient(try makeServer())
        defer { c.close() }
        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "green")
    }

    // MARK: - yellow

    func testFailedScanIsYellowWithScanAgain() throws {
        let dev = try seedStorageDevice()
        try seedScan(deviceID: dev, state: "failed")
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "yellow")
        let first = try XCTUnwrap(try reasons(s).first)
        XCTAssertEqual(first["id"] as? String, "scan.failed")
        XCTAssertEqual(first["action"] as? String, "scanAgain")
    }

    func testActiveWarningAlertIsYellow() throws {
        let dev = try seedKeyboardDevice()
        try db.api.seedAlert(id: "alr_w1", deviceID: dev, rule: "R4", severity: "warning",
                             state: "active", summary: "Typing burst.", why: "R4")
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "yellow")
        XCTAssertEqual(try reasons(s).first?["id"] as? String, "alert.warning")
    }

    func testStaleDefinitionsTurnACleanDriveYellow() throws {
        let dev = try seedStorageDevice()
        try seedScan(deviceID: dev, state: "clean")
        let c = try authedClient(try makeServer(definitionsAgeDays: 30))
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "yellow")
        let first = try XCTUnwrap(try reasons(s).first)
        XCTAssertEqual(first["id"] as? String, "definitions.stale")
        XCTAssertEqual(first["action"] as? String, "updateDefinitions")
    }

    // MARK: - grey (not checked)

    func testNeverScannedStorageIsGrey() throws {
        let dev = try seedStorageDevice()
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "grey")
        let first = try XCTUnwrap(try reasons(s).first)
        XCTAssertEqual(first["id"] as? String, "scan.never")
        XCTAssertEqual(first["action"] as? String, "scanAgain")
    }

    func testScannerMissingIsGreyWithInstallScanner() throws {
        let dev = try seedStorageDevice()
        let c = try authedClient(try makeServer(clamav: false))
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "grey")
        let first = try XCTUnwrap(try reasons(s).first)
        XCTAssertEqual(first["id"] as? String, "scanner.missing")
        XCTAssertEqual(first["action"] as? String, "installScanner")
    }

    func testKeyboardWithInputMonitoringOffIsGrey() throws {
        let dev = try seedKeyboardDevice()
        let c = try authedClient(try makeServer(inputMonitoring: false))
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "grey")
        let first = try XCTUnwrap(try reasons(s).first)
        XCTAssertEqual(first["id"] as? String, "sensor.off")
        XCTAssertEqual(first["action"] as? String, "grantInputMonitoring")
    }

    func testKeyboardGrantedMidRunIsGreyWithRestart() throws {
        // Permission granted while the daemon runs: the sensor opens at boot,
        // so the verdict says restart, never a false "Safe".
        let dev = try seedKeyboardDevice()
        let c = try authedClient(try makeServer(inputMonitoring: false,
                                                inputMonitoringResolver: { true }))
        defer { c.close() }

        let s = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "grey")
        let first = try XCTUnwrap(try reasons(s).first)
        XCTAssertEqual(first["id"] as? String, "sensor.restart")
        XCTAssertEqual(first["action"] as? String, "restartDaemon")
    }

    // MARK: - severity ordering over the wire

    func testDangerWinsOverMissingInformation() throws {
        // Critical alert on a never-scanned drive: red, with the unanswered
        // scan question still listed after the danger.
        let dev = try seedStorageDevice()
        try db.api.seedAlert(id: "alr_x1", deviceID: dev, rule: "R1", severity: "critical",
                             state: "active", summary: "Storage that also types.", why: "R1")
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let s = try safetyStatus(fromGet: c, deviceID: dev, id: 1)
        XCTAssertEqual(s["status"] as? String, "red")
        let ids = try reasons(s).map { $0["id"] as? String }
        XCTAssertEqual(ids, ["alert.critical", "scan.never"])
    }

    func testListAndGetAgreeOnTheVerdict() throws {
        let dev = try seedStorageDevice()
        try seedScan(deviceID: dev, state: "failed")
        try db.api.seedAlert(id: "alr_y1", deviceID: dev, rule: "R4", severity: "warning",
                             state: "active", summary: "Odd.", why: "R4")
        let c = try authedClient(try makeServer())
        defer { c.close() }

        let fromList = try safetyStatus(fromList: c, deviceID: dev, id: 1)
        let fromGet = try safetyStatus(fromGet: c, deviceID: dev, id: 2)
        XCTAssertEqual(fromList["status"] as? String, fromGet["status"] as? String)
        XCTAssertEqual(try reasons(fromList).map { $0["id"] as? String },
                       try reasons(fromGet).map { $0["id"] as? String })
    }
}
