// APIScanDriveTests.swift  (N8b — Gap A)
//
// The API `scan.start` must DRIVE the real ScanOrchestrator, not insert a
// placeholder row. These tests boot an APIServer with a ScanOrchestrator wired to
// the FAKE clamscan fixtures (Tests/Fixtures/clamav/*.sh) and assert that an
// agent/UI `scan.start` performs a real scan producing a terminal state + verdict,
// exactly like the mount-triggered path:
//   - a clean volume ends `clean` with a `scan.finished` event
//   - an infected volume ends `infected` with a finding + a critical scan alert
//   - `scan.cancel` on a running scan ends it `canceled`
// The scan is async (scan.start returns scanId + `running` immediately) and driven
// to terminal in the background; tests poll the shared store for the terminal state.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APIScanDriveTests: XCTestCase {
    private var stateDir: String!
    private var store: EventStore!
    private var api: APIStore!
    private var device = ""

    override func setUpWithError() throws {
        stateDir = makeTempStateDir()
        let dbPath = (stateDir as NSString).appendingPathComponent("plugsight.db")
        store = try EventStore(path: dbPath)
        api = APIStore(store: store)
        device = try store.upsertDevice(from: DeviceDescriptor(
            deviceKey: "d1", vid: 0x0781, pid: 0x5567, serial: "SD-1",
            vendorName: "SanDisk", productName: "SanDisk Ultra",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 6, usbProtocol: 0x50)],
            portPath: "0/1")).deviceID
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    // MARK: - Fixtures / helpers

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PlugsightDaemonTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures/clamav/\(name)")
            .path
    }

    private func clamscanDiscovery(_ script: String) -> EngineDiscovery {
        EngineDiscovery(
            clamdSocketPath: "/nope.sock", clamdSocketLive: { _ in false },
            candidateExecutables: ["clamscan": script], searchDirs: [],
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugsight-n8b-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a server whose Router drives the injected orchestrator.
    private func makeServer(discovery: EngineDiscovery, clamav: Bool = true) throws -> APIServer {
        let orchestrator = ScanOrchestrator(
            store: store, discovery: discovery,
            runner: ScanProcessRunner(), definitions: nil)
        let server = APIServer(
            store: store, stateDirectory: stateDir, daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: clamav),
            quarantineDirectory: (stateDir as NSString).appendingPathComponent("quarantine"),
            scanOrchestrator: orchestrator)
        try server.start()
        return server
    }

    /// Poll the shared store until the scan reaches a terminal state.
    @discardableResult
    private func waitForTerminal(_ scanId: String, timeout: TimeInterval = 6) throws -> StoredScan {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try api.getScan(id: scanId), s.isTerminal { return s }
            usleep(20_000)
        }
        return try api.getScan(id: scanId)!   // caller asserts on non-terminal
    }

    // MARK: - clean

    func testApiScanStartDrivesCleanScanToTerminal() throws {
        let server = try makeServer(discovery: clamscanDiscovery(fixture("clean.sh")))
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }

        let started = try XCTUnwrap(
            c.call(id: 1, method: "scan.start", params: ["volumePath": "/Volumes/UNTITLED"]).rpcResult)
        XCTAssertEqual(started["state"] as? String, "running", "scan.start returns running immediately")
        let scanId = try XCTUnwrap(started["scanId"] as? String)

        let terminal = try waitForTerminal(scanId)
        XCTAssertEqual(terminal.state, "clean", "a clean volume drives to clean")

        // scan.get over the wire reflects the terminal verdict.
        let got = try XCTUnwrap(c.call(id: 2, method: "scan.get", params: ["scanId": scanId]).rpcResult)
        XCTAssertEqual(got["state"] as? String, "clean")

        // A scan.finished event was appended (real orchestrator path, not a placeholder).
        let finished = try store.listEvents(filter: EventFilter(kind: "scan.finished"))
        XCTAssertEqual(finished.count, 1)
    }

    // MARK: - infected

    func testApiScanStartDrivesInfectedScanQuarantinesAndAlerts() throws {
        // A real volume with a real infected file the fake clamscan will report.
        let volume = try makeTempDir("vol")
        defer { try? FileManager.default.removeItem(at: volume) }
        let payload = volume.appendingPathComponent("payload.exe")
        try Data("EICAR-BYTES".utf8).write(to: payload)

        let server = try makeServer(discovery: clamscanDiscovery(fixture("infected-arg.sh")))
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }

        let started = try XCTUnwrap(
            c.call(id: 1, method: "scan.start", params: ["deviceId": device, "volumePath": volume.path]).rpcResult)
        let scanId = try XCTUnwrap(started["scanId"] as? String)

        let terminal = try waitForTerminal(scanId)
        XCTAssertEqual(terminal.state, "infected")

        // The finding was contained (default policy quarantine=true).
        let findings = try store.scanFindingRows(scanID: scanId)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.action, "quarantined")
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path),
                       "the infected file was moved out of the volume")

        // A critical scan_finding alert names the signature.
        let alerts = try store.scanAlertRows()
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.severity, "critical")
        XCTAssertTrue(alerts.first?.summary.contains("Eicar-Test-Signature") ?? false)
    }

    // MARK: - cancel

    func testApiScanCancelEndsRunningScanCanceled() throws {
        let server = try makeServer(discovery: clamscanDiscovery(fixture("hang.sh")))
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }

        let started = try XCTUnwrap(
            c.call(id: 1, method: "scan.start", params: ["volumePath": "/Volumes/UNTITLED"]).rpcResult)
        let scanId = try XCTUnwrap(started["scanId"] as? String)
        XCTAssertEqual(started["state"] as? String, "running")

        // The scan is hanging; cancel it and expect a canceled terminal state.
        let canceled = try XCTUnwrap(c.call(id: 2, method: "scan.cancel", params: ["scanId": scanId]).rpcResult)
        XCTAssertEqual(canceled["state"] as? String, "canceled")

        let terminal = try waitForTerminal(scanId)
        XCTAssertEqual(terminal.state, "canceled")
    }

    // MARK: - scanner unavailable (unchanged contract)

    func testApiScanStartWithoutScannerStaysUnavailable() throws {
        // clamav capability off -> scanner_unavailable with the install fix, even
        // though an orchestrator is wired.
        let server = try makeServer(discovery: clamscanDiscovery(fixture("clean.sh")), clamav: false)
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }
        let resp = try c.call(id: 1, method: "scan.start", params: ["volumePath": "/Volumes/UNTITLED"])
        let err = try XCTUnwrap(resp.rpcError)
        XCTAssertEqual((err["data"] as? [String: Any])?["kind"] as? String, "scanner_unavailable")
        XCTAssertTrue((err["message"] as? String ?? "").lowercased().contains("brew install clamav"))
    }
}
