// DaemonHygieneTests.swift  (Wave 1b)
//
// Daemon-truth hygiene at the assembly level:
//   1. Startup reconciles scans a previous daemon left `running` (a restart
//      mid-scan) to `failed` with the exact reason copy.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore
import PlugsightTestKit

final class DaemonHygieneTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_755_000_000)

    private func makeDB() throws -> EventStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugsight-hyg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try EventStore(path: dir.appendingPathComponent("plugsight.db").path)
    }

    private func makeDaemon(
        store: EventStore,
        events: [CollectorEvent] = [],
        scanOrchestrator: ScanOrchestrator? = nil,
        scanConfig: ScanConfig? = nil
    ) -> DaemonCore {
        DaemonCore(
            store: store,
            source: FakeDeviceEventSource(events: events),
            stateDirectory: makeTempStateDir(),
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: true),
            allowlist: Allowlist(patterns: []),
            scanOrchestrator: scanOrchestrator,
            scanConfig: scanConfig,
            clock: { self.base },
            bootTime: { self.base.addingTimeInterval(-86_400) }
        )
    }

    // MARK: - 1. Orphaned running scans reconcile at startup

    func testStartupFailsScansLeftRunningByAPreviousDaemon() throws {
        let store = try makeDB()
        // Seed what a killed daemon leaves behind: a scan stuck in `running`.
        let orphan = try store.createScan(
            deviceID: nil, volumePath: "/Volumes/STICK", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning STICK", at: base.addingTimeInterval(-600))

        let daemon = makeDaemon(store: store)
        try daemon.start()
        defer { daemon.stop() }

        let row = try XCTUnwrap(store.scanRow(id: orphan))
        XCTAssertEqual(row.state, "failed", "a restart must not leave scans running forever")
        XCTAssertNotNil(row.finishedAt)
        let finished = try store.listEvents(filter: EventFilter(kind: "scan.finished"))
        XCTAssertTrue(finished.contains { $0.summary.contains("Interrupted by a restart") },
                      "the reconcile event carries the exact reason; got \(finished.map(\.summary))")
    }

    // MARK: - 2. Retention wiring + one-time internal-volume cleanup

    func testStartupPruneHonorsLivePolicyRetentionDays() throws {
        let store = try makeDB()
        // 40-day-old event and scan; policy retention window of 30 days.
        let old = base.addingTimeInterval(-40 * 86_400)
        try store.appendEvent(kind: "device.attached", severity: "info",
                              summary: "Old event.", at: old)
        let oldScan = try store.createScan(
            deviceID: nil, volumePath: "/Volumes/OLD", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning OLD", at: old)
        try store.updateScan(id: oldScan, state: "clean", filesScanned: 1,
                             finishedSummary: "Scan finished: clean.", deviceID: nil,
                             at: old.addingTimeInterval(5))
        try APIStore(store: store).setPolicyKey("retentionDays", valueJSON: "30", actor: "test")

        let daemon = makeDaemon(store: store)
        try daemon.start()
        defer { daemon.stop() }

        XCTAssertNil(try store.scanRow(id: oldScan),
                     "the boot prune trims scans past the LIVE retentionDays")
        let markers = try store.listEvents(filter: EventFilter(kind: "monitoring.gap"))
        XCTAssertTrue(markers.contains { $0.summary.contains("retention") },
                      "pruning leaves its marker event; got \(markers.map(\.summary))")
        let oldEvents = try store.listEvents(filter: EventFilter(kind: "device.attached"))
        XCTAssertTrue(oldEvents.isEmpty, "events past retention are pruned")
    }

    func testStartupPruneDefaultRetentionKeepsRecentHistory() throws {
        let store = try makeDB()
        try store.appendEvent(kind: "device.attached", severity: "info",
                              summary: "Recent event.", at: base.addingTimeInterval(-86_400))
        let daemon = makeDaemon(store: store)
        try daemon.start()
        defer { daemon.stop() }
        XCTAssertEqual(try store.listEvents(filter: EventFilter(kind: "device.attached")).count, 1,
                       "the default 365-day window must not eat yesterday's history")
    }

    func testStartupCleansHistoricalFailedScansOnInternalSystemVolumes() throws {
        let store = try makeDB()
        func failedScan(_ path: String) throws -> String {
            let id = try store.createScan(
                deviceID: nil, volumePath: path, engine: "clamscan",
                defsAgeDays: nil, startedBy: "system",
                startedSummary: "Scanning \(path)", at: base.addingTimeInterval(-3_600))
            try store.updateScan(id: id, state: "failed", filesScanned: 0,
                                 finishedSummary: "Scan of \(path) failed (engine error).",
                                 deviceID: nil, at: base.addingTimeInterval(-3_590))
            return id
        }
        let junk = try failedScan("/System/Volumes/xarts")
        let real = try failedScan("/Volumes/STICK")

        let daemon = makeDaemon(store: store)
        try daemon.start()
        defer { daemon.stop() }

        XCTAssertNil(try store.scanRow(id: junk),
                     "pre-ddcb42a internal-volume failure rows are cleaned up at boot")
        XCTAssertNotNil(try store.scanRow(id: real),
                        "a real user-volume failure is history and stays")
    }

    // MARK: - 3. Auto-rescan dedup (one automatic attempt per volume per mount)

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

    private func stick(_ key: String) -> DeviceDescriptor {
        DeviceDescriptor(
            deviceKey: key, vid: 0x0951, pid: 0x1666, serial: "S-\(key)",
            vendorName: "Kingston", productName: "DataTraveler",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 0x06, usbProtocol: 0x50)],
            portPath: "20-7")
    }

    private func mount(_ key: String, path: String) -> CollectorEvent {
        .volumeMounted(VolumeDescriptor(deviceKey: key, volumePath: path,
                                        volumeName: "STICK", totalBytes: 1_000_000))
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return try condition()
    }

    private func makeScanDaemon(store: EventStore, events: [CollectorEvent]) -> DaemonCore {
        let orchestrator = ScanOrchestrator(
            store: store, discovery: clamscanDiscovery(fixture("clean.sh")),
            runner: ScanProcessRunner(), definitions: nil)
        let stateDir = makeTempStateDir()
        return DaemonCore(
            store: store,
            source: FakeDeviceEventSource(events: events),
            stateDirectory: stateDir,
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: true),
            allowlist: Allowlist(patterns: []),
            scanOrchestrator: orchestrator,
            scanConfig: ScanConfig(timeout: 10, quarantineEnabled: true,
                                   definitionsWarnDays: 7,
                                   quarantineDirectory: stateDir + "/quarantine"),
            clock: { self.base },
            bootTime: { self.base.addingTimeInterval(-86_400) })
    }

    private func startedScanCount(_ store: EventStore) throws -> Int {
        try store.listEvents(filter: EventFilter(kind: "scan.started")).count
    }

    func testRepeatedMountEventsScanOnlyOncePerMountSession() async throws {
        let store = try makeDB()
        try APIStore(store: store).setPolicyKey("scanOnMount", valueJSON: "true", actor: "test")
        let key = "usb-dedup-1"
        let daemon = makeScanDaemon(store: store, events: [
            .attached(stick(key)),
            mount(key, path: "/Volumes/STICK"),
            mount(key, path: "/Volumes/STICK"),   // duplicate announce, no unmount
        ])
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        _ = try waitUntil { try store.listEvents(filter: EventFilter(kind: "scan.finished")).count >= 1 }
        XCTAssertEqual(try startedScanCount(store), 1,
                       "a second mount announce without an unmount must not rescan")
    }

    func testUnmountAndRemountScansAgain() async throws {
        let store = try makeDB()
        try APIStore(store: store).setPolicyKey("scanOnMount", valueJSON: "true", actor: "test")
        let key = "usb-dedup-2"
        let daemon = makeScanDaemon(store: store, events: [
            .attached(stick(key)),
            mount(key, path: "/Volumes/STICK"),
            .volumeUnmounted(deviceKey: key, volumePath: "/Volumes/STICK",
                             at: base.addingTimeInterval(5)),
            mount(key, path: "/Volumes/STICK"),
        ])
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        let sawBoth = try waitUntil { try self.startedScanCount(store) >= 2 }
        XCTAssertTrue(sawBoth, "an unmount + remount is a fresh mount and scans again")
        XCTAssertEqual(try startedScanCount(store), 2)
    }

    // MARK: - 4. Declined mount scans are recorded as skipped

    func testMountOnTrustedDeviceRecordsSkippedScanWithReason() async throws {
        let store = try makeDB()
        try APIStore(store: store).setPolicyKey("scanOnMount", valueJSON: "true", actor: "test")
        let key = "usb-trusted-1"
        let device = stick(key)
        // Pre-trust the device (the daemon's attach upsert matches the same
        // identity and keeps the tier).
        let upsert = try store.upsertDevice(from: device, at: base.addingTimeInterval(-60))
        _ = try APIStore(store: store).setTrust(deviceID: upsert.deviceID, tier: "trusted",
                                                note: "mine", actor: "test")

        let daemon = makeScanDaemon(store: store, events: [
            .attached(device),
            mount(key, path: "/Volumes/STICK"),
        ])
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        XCTAssertEqual(try startedScanCount(store), 0, "a trusted device is not scanned on mount")
        let skipped = try store.listEvents(filter: EventFilter(kind: "scan.skipped"))
        XCTAssertEqual(skipped.count, 1, "the decline is recorded; got \(skipped.map(\.summary))")
        XCTAssertTrue(try XCTUnwrap(skipped.first).summary.contains("Device is trusted"))
        let scan = try XCTUnwrap(APIStore(store: store).listScans().first)
        XCTAssertEqual(scan.state, "skipped")
        XCTAssertEqual(scan.deviceID, upsert.deviceID, "the skip is attributed to the device")
    }

    // MARK: - 5. Input Monitoring freshness on status.get

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Bool
        init(_ value: Bool) { _value = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    private func makeServer(
        bootInputMonitoring: Bool,
        resolver: (@Sendable () -> Bool)?
    ) throws -> (server: APIServer, stateDir: String) {
        let stateDir = makeTempStateDir()
        let store = try EventStore(path: (stateDir as NSString).appendingPathComponent("plugsight.db"))
        let server = APIServer(
            store: store, stateDirectory: stateDir, daemonVersion: "1.0-test",
            capabilities: Capabilities(inputMonitoring: bootInputMonitoring,
                                       endpointSecurity: false, clamav: false),
            inputMonitoringResolver: resolver)
        try server.start()
        return (server, stateDir)
    }

    func testStatusGetSeesInputMonitoringGrantedAfterBootWithoutRestart() throws {
        let granted = Flag(false)
        let (server, _) = try makeServer(bootInputMonitoring: false,
                                         resolver: { granted.value })
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }

        // Not granted yet: permission false, sensor off.
        var perms = try XCTUnwrap(
            XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)["permissions"] as? [String: Any])
        XCTAssertEqual(perms["inputMonitoring"] as? Bool, false)
        XCTAssertEqual(perms["inputMonitoringSensor"] as? String, "off")

        // The user grants Input Monitoring while the daemon runs.
        granted.value = true
        perms = try XCTUnwrap(
            XCTUnwrap(c.call(id: 2, method: "status.get").rpcResult)["permissions"] as? [String: Any])
        XCTAssertEqual(perms["inputMonitoring"] as? Bool, true,
                       "the fresh grant registers without a daemon restart")
        XCTAssertEqual(perms["inputMonitoringSensor"] as? String, "restart_required",
                       "honesty: the HID sensor only opens at boot, so it still needs a restart")
    }

    func testStatusGetSensorActiveWhenGrantedAtBoot() throws {
        let (server, _) = try makeServer(bootInputMonitoring: true, resolver: { true })
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }
        let perms = try XCTUnwrap(
            XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)["permissions"] as? [String: Any])
        XCTAssertEqual(perms["inputMonitoring"] as? Bool, true)
        XCTAssertEqual(perms["inputMonitoringSensor"] as? String, "active")
    }

    func testStatusGetWithoutResolverFallsBackToBootSnapshot() throws {
        let (server, _) = try makeServer(bootInputMonitoring: true, resolver: nil)
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }
        let perms = try XCTUnwrap(
            XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)["permissions"] as? [String: Any])
        XCTAssertEqual(perms["inputMonitoring"] as? Bool, true)
        XCTAssertEqual(perms["inputMonitoringSensor"] as? String, "active")
    }

    func testScoreGetExplainsRestartWhenGrantArrivesMidRun() throws {
        let granted = Flag(true)
        let stateDir = makeTempStateDir()
        let store = try EventStore(path: (stateDir as NSString).appendingPathComponent("plugsight.db"))
        let deviceID = try store.upsertDevice(from: stick("usb-score-1"), at: base).deviceID
        let server = APIServer(
            store: store, stateDirectory: stateDir, daemonVersion: "1.0-test",
            capabilities: Capabilities(inputMonitoring: false,   // sensor never opened
                                       endpointSecurity: false, clamav: false),
            inputMonitoringResolver: { granted.value })
        try server.start()
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }

        let result = try XCTUnwrap(
            c.call(id: 1, method: "score.get", params: ["deviceId": deviceID]).rpcResult)
        // Null-not-zero holds: the sensor is NOT collecting, so no number.
        XCTAssertNil(result["score"] as? Int)
        XCTAssertEqual(result["sensorAvailable"] as? Bool, false)
        let explanation = try XCTUnwrap(result["explanation"] as? String)
        XCTAssertTrue(explanation.contains("restart"),
                      "the explanation must say a restart is needed; got \(explanation)")
    }
}
