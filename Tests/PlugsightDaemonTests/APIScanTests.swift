// APIScanTests.swift
//
// Unit D: scan.start / scan.get / scan.cancel / scans.list, plus the
// scanner_unavailable error whose message names the install fix. N4 provides
// routing + DTOs + store reads/writes; the real ClamAV run is N7/N8.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APITestsScan: XCTestCase {
    private var server: APIServer!
    private var stateDir: String!
    private var db: TestDB!
    private var device = ""

    override func setUpWithError() throws {
        stateDir = makeTempStateDir()
        db = try makeTestDB(inDir: stateDir)
        let d = try db.event.upsertDevice(from: DeviceDescriptor(
            deviceKey: "d1", vid: 0x0781, pid: 0x5567, serial: "SD-1",
            vendorName: "SanDisk", productName: "SanDisk Ultra",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 6, usbProtocol: 0x50)],
            portPath: "0/1"))
        device = d.deviceID
        server = try makeServer(clamav: true)
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    private func makeServer(clamav: Bool) throws -> APIServer {
        try APIServer(databasePath: db.path, stateDirectory: stateDir, daemonVersion: "1.0.0",
                      capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: clamav))
    }

    // MARK: - scan.start

    func testScanStartReturnsRunningScan() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "scan.start", params: ["volumePath": "/Volumes/UNTITLED"]).rpcResult)
        XCTAssertEqual(r["state"] as? String, "running")
        XCTAssertNotNil(r["scanId"] as? String)
    }

    func testScanStartByDeviceId() throws {
        // scan.start by deviceId resolves the device's currently-mounted volume.
        _ = try db.api.appendEvent(kind: "volume.mounted", severity: "info", deviceID: device,
                                   summary: "Volume mounted.",
                                   detail: "{\"v\":1,\"volumePath\":\"/Volumes/UNTITLED\"}")
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "scan.start", params: ["deviceId": device]).rpcResult)
        XCTAssertEqual(r["state"] as? String, "running")
    }

    func testScanStartMissingTargetIsInvalidParams() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "scan.start")
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "invalid_params")
    }

    func testScanStartWithoutScannerIsUnavailableAndNamesFix() throws {
        // A fresh server with ClamAV capability off, in its own state dir.
        let dir2 = makeTempStateDir()
        defer { try? FileManager.default.removeItem(atPath: dir2) }
        let noScanner = try APIServer(databasePath: db.path, stateDirectory: dir2, daemonVersion: "1.0.0",
                                      capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: false))
        try noScanner.start()
        defer { noScanner.stop() }
        let c = try authedClient(noScanner)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "scan.start", params: ["volumePath": "/Volumes/UNTITLED"])
        let err = try XCTUnwrap(resp.rpcError)
        XCTAssertEqual((err["data"] as? [String: Any])?["kind"] as? String, "scanner_unavailable")
        XCTAssertTrue((err["message"] as? String ?? "").lowercased().contains("brew install clamav"),
                      "message must name the install fix")
    }

    // MARK: - scan.get

    func testScanGetReturnsStateAndFindings() throws {
        // Seed a finished, infected scan with a quarantined finding.
        let scan = try db.api.insertScan(deviceID: device, volumePath: "/Volumes/UNTITLED", engine: "clamdscan", startedBy: "system")
        try db.api.setScanState(id: scan.id, state: "infected", filesScanned: 128, finishedAt: Date())
        try db.api.seedFinding(scanID: scan.id, filePath: "/Volumes/UNTITLED/evil.exe",
                               signature: "Win.Trojan.Test", action: "quarantined", quarantinePath: "/q/abc")
        let c = try authedClient(server)
        defer { c.close() }
        let r = try XCTUnwrap(c.call(id: 1, method: "scan.get", params: ["scanId": scan.id]).rpcResult)
        XCTAssertEqual(r["state"] as? String, "infected")
        XCTAssertEqual(r["filesScanned"] as? Int, 128)
        // Reconciled shape: per-file verdicts + quarantine records (03), not findings.
        let verdicts = try XCTUnwrap(r["verdicts"] as? [[String: Any]])
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts[0]["verdict"] as? String, "infected")
        XCTAssertEqual(verdicts[0]["signature"] as? String, "Win.Trojan.Test")
        let quarantine = try XCTUnwrap(r["quarantine"] as? [[String: Any]])
        XCTAssertEqual(quarantine.count, 1)
        XCTAssertEqual(quarantine[0]["signature"] as? String, "Win.Trojan.Test")
        // quarantineId is the sha-256 leaf of the quarantine path ("/q/abc" -> "abc").
        XCTAssertEqual(quarantine[0]["quarantineId"] as? String, "abc")
        XCTAssertEqual(quarantine[0]["containment"] as? String, "quarantined")
    }

    func testScanGetUnknownIsNotFound() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "scan.get", params: ["scanId": "scn_nope"])
        XCTAssertEqual((resp.rpcError?["data"] as? [String: Any])?["kind"] as? String, "not_found")
    }

    // MARK: - scan.cancel

    func testScanCancelRunningScan() throws {
        let c = try authedClient(server)
        defer { c.close() }
        let started = try XCTUnwrap(c.call(id: 1, method: "scan.start", params: ["volumePath": "/Volumes/UNTITLED"]).rpcResult)
        let scanId = try XCTUnwrap(started["scanId"] as? String)
        let r = try XCTUnwrap(c.call(id: 2, method: "scan.cancel", params: ["scanId": scanId]).rpcResult)
        XCTAssertEqual(r["state"] as? String, "canceled")
    }

    func testScanCancelTerminalIsConflict() throws {
        let scan = try db.api.insertScan(deviceID: device, volumePath: "/Volumes/UNTITLED", engine: "clamdscan", startedBy: "system")
        try db.api.setScanState(id: scan.id, state: "clean", filesScanned: 10, finishedAt: Date())
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "scan.cancel", params: ["scanId": scan.id])
        let err = try XCTUnwrap(resp.rpcError)
        XCTAssertEqual((err["data"] as? [String: Any])?["kind"] as? String, "conflict")
        XCTAssertEqual((err["data"] as? [String: Any])?["state"] as? String, "clean")
    }

    // MARK: - scans.list

    func testScansListByDevice() throws {
        _ = try db.api.insertScan(deviceID: device, volumePath: "/Volumes/A", engine: "clamdscan", startedBy: "system")
        _ = try db.api.insertScan(deviceID: nil, volumePath: "/Volumes/B", engine: "clamscan", startedBy: "system")
        let c = try authedClient(server)
        defer { c.close() }
        let all = try XCTUnwrap(c.call(id: 1, method: "scans.list").rpcResult)
        XCTAssertEqual((all["scans"] as? [[String: Any]])?.count, 2)
        let mine = try XCTUnwrap(c.call(id: 2, method: "scans.list", params: ["filter": ["deviceId": device]]).rpcResult)
        XCTAssertEqual((mine["scans"] as? [[String: Any]])?.count, 1)
    }
}
