// ScanPolicyConfigTests.swift  (N8b — Gap B)
//
// The scan config must come from the LIVE `policy` rows, not hardcoded constants.
// A `policy.set` (e.g. quarantine=false, scanTimeoutMinutes) must take effect for
// subsequent scans, on BOTH the API `scan.start` path and the mount-triggered
// path.
//
//   - ScanConfigResolver overlays policy rows on the v1 defaults (unit).
//   - An API scan.start with policy quarantine=false leaves an infected file in
//     place with a `reported_only` finding (not quarantined).
//   - A mount-triggered scan with policy quarantine=false does the same.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore
import PlugsightTestKit

final class ScanPolicyConfigTests: XCTestCase {

    // MARK: - Fixtures / helpers

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/clamav/\(name)").path
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

    // MARK: - ScanConfigResolver (unit)

    func testResolverOverlaysPolicyRowsOnDefaults() {
        let base = ScanConfig.defaults(quarantineDirectory: "/q")
        let rows: [String: Data] = [
            "quarantine": Data("false".utf8),
            "scanTimeoutMinutes": Data("3".utf8),
            "definitionsWarnDays": Data("14".utf8),
        ]
        let resolved = ScanConfigResolver.resolve(base: base, policyRaw: rows)
        XCTAssertFalse(resolved.quarantineEnabled, "policy quarantine=false takes effect")
        XCTAssertEqual(resolved.timeout, 180, "scanTimeoutMinutes 3 -> 180s")
        XCTAssertEqual(resolved.definitionsWarnDays, 14)
        XCTAssertEqual(resolved.quarantineDirectory, "/q", "quarantine dir is preserved from the base")
    }

    func testResolverEmptyPolicyEqualsBase() {
        let base = ScanConfig(timeout: 42, quarantineEnabled: true,
                              definitionsWarnDays: 9, quarantineDirectory: "/q")
        XCTAssertEqual(ScanConfigResolver.resolve(base: base, policyRaw: [:]), base)
    }

    // MARK: - API scan.start honors live policy

    func testApiScanStartHonorsLivePolicyQuarantineFalse() throws {
        let stateDir = makeTempStateDir()
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        let store = try EventStore(path: (stateDir as NSString).appendingPathComponent("plugsight.db"))
        let api = APIStore(store: store)

        // Turn quarantine OFF in policy BEFORE scanning.
        try api.setPolicyKey("quarantine", valueJSON: "false", actor: "test")

        let volume = try makeTempDir("vol")
        defer { try? FileManager.default.removeItem(at: volume) }
        let payload = volume.appendingPathComponent("payload.exe")
        try Data("EICAR-BYTES".utf8).write(to: payload)

        let orchestrator = ScanOrchestrator(
            store: store, discovery: clamscanDiscovery(fixture("infected-arg.sh")),
            runner: ScanProcessRunner(), definitions: nil)
        let server = APIServer(
            store: store, stateDirectory: stateDir, daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
            quarantineDirectory: (stateDir as NSString).appendingPathComponent("quarantine"),
            scanOrchestrator: orchestrator)
        try server.start()
        defer { server.stop() }

        let c = try authedClient(server)
        defer { c.close() }
        let started = try XCTUnwrap(
            c.call(id: 1, method: "scan.start", params: ["volumePath": volume.path]).rpcResult)
        let scanId = try XCTUnwrap(started["scanId"] as? String)

        // Await terminal.
        let deadline = Date().addingTimeInterval(6)
        var terminal: StoredScan?
        while Date() < deadline {
            if let s = try api.getScan(id: scanId), s.isTerminal { terminal = s; break }
            usleep(20_000)
        }
        let final = try XCTUnwrap(terminal)
        XCTAssertEqual(final.state, "infected")

        // quarantine=false -> the finding is reported_only and the file stays put.
        let findings = try store.scanFindingRows(scanID: scanId)
        XCTAssertEqual(findings.first?.action, "reported_only",
                       "live policy quarantine=false must yield a reported_only finding")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path),
                      "a report-only finding leaves the file in place")
    }

    // MARK: - Mount-triggered scan honors live policy

    func testMountScanHonorsLivePolicyQuarantineFalse() async throws {
        let stateDir = makeTempStateDir()
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        let store = try EventStore(path: (stateDir as NSString).appendingPathComponent("plugsight.db"))
        let api = APIStore(store: store)
        try api.setPolicyKey("quarantine", valueJSON: "false", actor: "test")
        // Mount scanning is gated on policy `scanOnMount` (05); enable it.
        try api.setPolicyKey("scanOnMount", valueJSON: "true", actor: "test")

        let volume = try makeTempDir("mvol")
        defer { try? FileManager.default.removeItem(at: volume) }
        let payload = volume.appendingPathComponent("payload.exe")
        try Data("EICAR-BYTES".utf8).write(to: payload)

        let storageOnly = DeviceDescriptor(
            deviceKey: "usb-mount", vid: 0x0951, pid: 0x1666, serial: "STICK01",
            vendorName: "Kingston", productName: "DataTraveler",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 0x06, usbProtocol: 0x50)],
            portPath: "20-3")
        let events: [CollectorEvent] = [
            .attached(storageOnly),
            .volumeMounted(VolumeDescriptor(deviceKey: storageOnly.deviceKey,
                                            volumePath: volume.path, volumeName: "STICK",
                                            totalBytes: 1_000_000)),
        ]

        let orchestrator = ScanOrchestrator(
            store: store, discovery: clamscanDiscovery(fixture("infected-arg.sh")),
            runner: ScanProcessRunner(), definitions: nil)
        let base = Date(timeIntervalSince1970: 1_755_000_000)
        // Injected config has quarantine=true (the old hardcoded default); the live
        // policy row (false) must WIN at scan time.
        let daemon = DaemonCore(
            store: store,
            source: FakeDeviceEventSource(events: events),
            stateDirectory: stateDir,
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: true),
            allowlist: Allowlist(patterns: []),
            scanOrchestrator: orchestrator,
            scanConfig: ScanConfig(timeout: 10, quarantineEnabled: true,
                                   definitionsWarnDays: 7,
                                   quarantineDirectory: (stateDir as NSString).appendingPathComponent("quarantine")),
            clock: { base }, bootTime: { base.addingTimeInterval(-86_400) })
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        // The mount scan now runs OFF the analyzer loop (C1), so await its
        // terminal state rather than reading immediately.
        let deadline = Date().addingTimeInterval(6)
        var terminal: StoredScan?
        while Date() < deadline {
            if let s = try api.listScans().first, s.isTerminal { terminal = s; break }
            usleep(20_000)
        }

        // The scan ran, found the file, and REPORTED it (did not quarantine).
        let scan = try XCTUnwrap(terminal)
        XCTAssertEqual(scan.state, "infected")
        let findings = try store.scanFindingRows(scanID: scan.id)
        XCTAssertEqual(findings.first?.action, "reported_only",
                       "the mount scan must honor the live policy quarantine=false")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }
}
