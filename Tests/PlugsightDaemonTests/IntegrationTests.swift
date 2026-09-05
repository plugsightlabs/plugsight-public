// IntegrationTests.swift  (N8)
//
// Daemon assembly integration tests (docs/spec/07 N8): boot `DaemonCore` on a
// `FakeDeviceEventSource` + a temp-file store + a REAL API socket, drive 02's
// canonical T1 data flow end to end, and assert the exact event sequence, the
// `event.appended` fanout, degraded-capability reporting, monitoring-gap
// detection (L10), the seed-DB boot path (G), and the launchd plist (F).

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore
import PlugsightTestKit

final class IntegrationTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed base instant so scorer math is deterministic.
    private let base = Date(timeIntervalSince1970: 1_755_000_000)

    private func makeDB() throws -> (store: EventStore, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugsight-n8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("plugsight.db").path
        return (try EventStore(path: path), path)
    }

    private func makeDaemon(
        events: [CollectorEvent],
        capabilities: Capabilities = Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
        seed: ((EventStore) throws -> Void)? = nil,
        scanOrchestrator: ScanOrchestrator? = nil,
        scanConfig: ScanConfig? = nil,
        clock: Date? = nil,
        bootTime: Date? = nil
    ) throws -> (daemon: DaemonCore, store: EventStore) {
        let (store, _) = try makeDB()
        try seed?(store)
        let stateDir = makeTempStateDir()
        let clockDate = clock ?? base
        let bootDate = bootTime ?? base.addingTimeInterval(-86_400)
        let daemon = DaemonCore(
            store: store,
            source: FakeDeviceEventSource(events: events),
            stateDirectory: stateDir,
            daemonVersion: "0.1.0-test",
            capabilities: capabilities,
            allowlist: Allowlist(patterns: []),
            scanOrchestrator: scanOrchestrator,
            scanConfig: scanConfig,
            clock: { clockDate },
            bootTime: { bootDate }
        )
        return (daemon, store)
    }

    /// The BadUSB-shaped descriptor of the canonical T1 story: presents as mass
    /// storage (usbClass 8 FIRST in configuration order) and hides a HID
    /// keyboard interface (usbClass 3, protocol 1).
    private var badUSB: DeviceDescriptor {
        DeviceDescriptor(
            deviceKey: "usb-loc-0x14100000", vid: 0x1234, pid: 0x5678,
            serial: "BADUSB01", vendorName: "Generic", productName: "Flash Disk",
            interfaces: [
                InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 0x06, usbProtocol: 0x50),
                InterfaceDescriptor(seq: 1, usbClass: 0x03, usbSubclass: 0x01, usbProtocol: 0x01),
            ],
            portPath: "20-1"
        )
    }

    /// Injector cadence: first key 400 ms after attach, then 30 more keys at a
    /// robotic 20 ms inter-key interval (31 keystrokes total).
    private var injectorBurst: [CollectorEvent] {
        var events: [CollectorEvent] = [
            .inputActivity(InputTiming(at: base.addingTimeInterval(0.4), interKeyIntervalMs: nil))
        ]
        for i in 1...30 {
            events.append(.inputActivity(InputTiming(
                at: base.addingTimeInterval(0.4 + 0.02 * Double(i)),
                interKeyIntervalMs: 20
            )))
        }
        return events
    }

    /// Events in the order they were appended (listEvents is newest-first).
    private func ascendingEvents(_ store: EventStore) throws -> [StoredEvent] {
        try store.listEvents(limit: 500).reversed()
    }

    // MARK: - The canonical T1 flow (02 "Data flow, end to end")

    func testT1BadUSBFlowAppendsExactSequenceAndFansOut() async throws {
        let (daemon, store) = try makeDaemon(events: [.attached(badUSB)] + injectorBurst)
        try daemon.start()
        defer { daemon.stop() }

        // Subscribe a live tail over the REAL socket BEFORE events flow.
        let client = try authedClient(daemon.server, name: "tail", kind: "cli")
        defer { client.close() }
        _ = try XCTUnwrap(client.call(id: 1, method: "events.tail").rpcResult)

        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        // The exact appended sequence of the T1 walkthrough.
        let events = try ascendingEvents(store)
        let kinds = events.map(\.kind)
        XCTAssertEqual(kinds, [
            "daemon.started",
            "device.attached",
            "mismatch.detected",
            "alert.raised",
            "hid.typing_burst",
            "score.changed",
            "alert.raised",
        ], "expected the canonical T1 sequence, got \(kinds)")

        // device.attached names the device and what it presents as.
        let attached = events[1]
        XCTAssertEqual(attached.severity, "info")
        XCTAssertTrue(attached.summary.contains("plugged in"), attached.summary)
        XCTAssertNotNil(attached.deviceID)

        // mismatch.detected is the R1 hidden-keyboard critical.
        let mismatch = events[2]
        XCTAssertEqual(mismatch.severity, "critical")
        XCTAssertTrue(mismatch.detail.contains("r1_hidden_keyboard"), mismatch.detail)

        // alert.raised (critical) carries the alert id.
        let raised = events[3]
        XCTAssertEqual(raised.severity, "critical")
        let alertID = try XCTUnwrap(raised.alertID)
        XCTAssertTrue(alertID.hasPrefix("alr_"))

        // hid.typing_burst quotes the burst facts.
        let burst = events[4]
        XCTAssertEqual(burst.severity, "notice")
        XCTAssertTrue(burst.summary.contains("31 keys"), burst.summary)

        // score.changed carries the high score; the alert escalates on it.
        let scoreChanged = events[5]
        XCTAssertTrue(scoreChanged.summary.contains("70"), scoreChanged.summary)
        let escalated = events[6]
        XCTAssertEqual(escalated.alertID, alertID,
                       "the score escalates the SAME alert the mismatch raised")
        XCTAssertTrue(escalated.summary.lowercased().contains("escalat"), escalated.summary)

        // Every post-subscribe append fanned out over event.appended, in order.
        var notified: [String] = []
        for _ in 0..<6 {
            guard let line = client.readLine() else { break }
            XCTAssertEqual(line["method"] as? String, "event.appended")
            let params = line["params"] as? [String: Any]
            notified.append(params?["kind"] as? String ?? "?")
        }
        XCTAssertEqual(notified, [
            "device.attached", "mismatch.detected", "alert.raised",
            "hid.typing_burst", "score.changed", "alert.raised",
        ])

        // The alert is ONE active critical R1 alert (escalation did not fork it).
        let alerts = try XCTUnwrap(client.call(id: 2, method: "alerts.list").rpcResult)
        let list = try XCTUnwrap(alerts["alerts"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["severity"] as? String, "critical")
        XCTAssertEqual(list[0]["state"] as? String, "active")
        XCTAssertEqual(list[0]["rule"] as? String, "R1")

        // The score snapshot persisted (step C): score.get renders it.
        let deviceID = try XCTUnwrap(attached.deviceID)
        let score = try XCTUnwrap(client.call(id: 3, method: "score.get",
                                              params: ["deviceId": deviceID]).rpcResult)
        XCTAssertEqual(score["score"] as? Int, 70)
        XCTAssertEqual(score["confidence"] as? String, "high")
        let signals = try XCTUnwrap(score["signals"] as? [[String: Any]])
        XCTAssertFalse(signals.isEmpty, "score snapshot must carry its signal breakdown")

        // Clean shutdown appends daemon.stopped.
        daemon.stop()
        let finalKinds = try ascendingEvents(store).map(\.kind)
        XCTAssertEqual(finalKinds.last, "daemon.stopped")
    }

    func testBenignKeyboardScoresZeroAndNoAlert() async throws {
        // A plain keyboard at human cadence: late first key (5 s), irregular
        // intervals (alternating 100/200 ms -> high stddev). Score 0, no alert.
        let keyboard = DeviceDescriptor(
            deviceKey: "usb-loc-0x14200000", vid: 0x046D, pid: 0xC31C,
            serial: "KB01", vendorName: "Logitech", productName: "K120",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0x01, usbProtocol: 0x01)],
            portPath: "20-2"
        )
        var events: [CollectorEvent] = [
            .attached(keyboard),
            .inputActivity(InputTiming(at: base.addingTimeInterval(5.0), interKeyIntervalMs: nil)),
        ]
        var t = 5.0
        for i in 1...19 {
            let interval = (i % 2 == 1) ? 100 : 200
            t += Double(interval) / 1000
            events.append(.inputActivity(InputTiming(at: base.addingTimeInterval(t), interKeyIntervalMs: interval)))
        }

        let (daemon, store) = try makeDaemon(events: events)
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        let kinds = try ascendingEvents(store).map(\.kind)
        XCTAssertEqual(kinds, ["daemon.started", "device.attached", "hid.typing_burst", "score.changed"],
                       "benign flow must not mismatch or alert; got \(kinds)")

        let client = try authedClient(daemon.server)
        defer { client.close() }
        let alerts = try XCTUnwrap(client.call(id: 1, method: "alerts.list").rpcResult)
        XCTAssertEqual((alerts["alerts"] as? [[String: Any]])?.count, 0)

        let devices = try XCTUnwrap(client.call(id: 2, method: "devices.list").rpcResult)
        let device = try XCTUnwrap((devices["devices"] as? [[String: Any]])?.first)
        let score = try XCTUnwrap(client.call(id: 3, method: "score.get",
                                              params: ["deviceId": device["deviceId"] as? String ?? ""]).rpcResult)
        XCTAssertEqual(score["score"] as? Int, 0)
    }

    // MARK: - Degraded-capability reporting (D)

    func testStatusGetReportsEachDegradedCombination() throws {
        let combos: [(caps: Capabilities, monitoring: String)] = [
            (Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true), "active"),
            (Capabilities(inputMonitoring: false, endpointSecurity: true, clamav: true), "degraded"),
            (Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: true), "degraded"),
            (Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: false), "degraded"),
            (Capabilities(inputMonitoring: false, endpointSecurity: false, clamav: false), "degraded"),
        ]
        for combo in combos {
            let (daemon, _) = try makeDaemon(events: [], capabilities: combo.caps)
            try daemon.start()
            defer { daemon.stop() }

            // auth.hello reports the same capability flags.
            let client = try UDSTestClient(socketPath: daemon.server.socketPath)
            defer { client.close() }
            let hello = try client.hello(token: try readToken(daemon.server))
            let helloCaps = try XCTUnwrap((hello.rpcResult)?["capabilities"] as? [String: Any])
            XCTAssertEqual(helloCaps["inputMonitoring"] as? Bool, combo.caps.inputMonitoring)
            XCTAssertEqual(helloCaps["endpointSecurity"] as? Bool, combo.caps.endpointSecurity)
            XCTAssertEqual(helloCaps["clamav"] as? Bool, combo.caps.clamav)

            let status = try XCTUnwrap(client.call(id: 1, method: "status.get").rpcResult)
            XCTAssertEqual(status["monitoring"] as? String, combo.monitoring, "caps \(combo.caps)")
            let permissions = try XCTUnwrap(status["permissions"] as? [String: Any])
            XCTAssertEqual(permissions["inputMonitoring"] as? Bool, combo.caps.inputMonitoring)
            XCTAssertEqual(permissions["esExtension"] as? String,
                           combo.caps.endpointSecurity ? "active" : "inactive")
            let scanner = try XCTUnwrap(status["scanner"] as? [String: Any])
            XCTAssertEqual(scanner["available"] as? Bool, combo.caps.clamav)
        }
    }

    // MARK: - Monitoring-gap detection on startup (E, L10)

    func testMonitoringGapWrittenOnUncleanShutdownWithMachineUp() throws {
        let t0 = base
        let lastEventAt = base.addingTimeInterval(600)
        let now = lastEventAt.addingTimeInterval(4 * 3600)

        let (daemon, store) = try makeDaemon(
            events: [],
            seed: { store in
                // Unclean: a daemon.started with NO daemon.stopped after it.
                try store.appendEvent(kind: "daemon.started", severity: "info",
                                      summary: "Plugsight daemon started.", at: t0)
                try store.appendEvent(kind: "device.attached", severity: "info",
                                      summary: "Some device plugged in.", at: lastEventAt)
            },
            clock: now,
            bootTime: t0.addingTimeInterval(-3600)   // machine up across the gap
        )
        try daemon.start()
        defer { daemon.stop() }

        let kinds = try ascendingEvents(store).map(\.kind)
        XCTAssertEqual(kinds, ["daemon.started", "device.attached", "monitoring.gap", "daemon.started"],
                       "got \(kinds)")
        let gap = try XCTUnwrap(store.listEvents(filter: EventFilter(kind: "monitoring.gap")).first)
        XCTAssertEqual(gap.severity, "notice")
        XCTAssertTrue(gap.summary.contains("Monitoring was off"), gap.summary)
        XCTAssertTrue(gap.detail.contains("\"from\""), gap.detail)
        XCTAssertTrue(gap.detail.contains("\"to\""), gap.detail)

        // status.get surfaces the gap (absence of data is data).
        let client = try authedClient(daemon.server)
        defer { client.close() }
        let status = try XCTUnwrap(client.call(id: 1, method: "status.get").rpcResult)
        let gaps = try XCTUnwrap(status["monitoringGaps"] as? [[String: Any]])
        XCTAssertEqual(gaps.count, 1)
    }

    func testNoGapAfterCleanShutdown() throws {
        let (daemon, store) = try makeDaemon(
            events: [],
            seed: { store in
                try store.appendEvent(kind: "daemon.started", severity: "info",
                                      summary: "started", at: self.base)
                try store.appendEvent(kind: "daemon.stopped", severity: "info",
                                      summary: "stopped", at: self.base.addingTimeInterval(60))
            },
            clock: base.addingTimeInterval(7200),
            bootTime: base.addingTimeInterval(-3600)
        )
        try daemon.start()
        defer { daemon.stop() }
        let gaps = try store.listEvents(filter: EventFilter(kind: "monitoring.gap"))
        XCTAssertTrue(gaps.isEmpty, "a clean shutdown is not a monitoring gap")
    }

    func testNoGapWhenMachineRebootedAfterLastEvent() throws {
        let (daemon, store) = try makeDaemon(
            events: [],
            seed: { store in
                try store.appendEvent(kind: "daemon.started", severity: "info",
                                      summary: "started", at: self.base)
                try store.appendEvent(kind: "device.attached", severity: "info",
                                      summary: "device", at: self.base.addingTimeInterval(60))
            },
            clock: base.addingTimeInterval(7200),
            bootTime: base.addingTimeInterval(3600)   // rebooted AFTER the last event
        )
        try daemon.start()
        defer { daemon.stop() }
        let gaps = try store.listEvents(filter: EventFilter(kind: "monitoring.gap"))
        XCTAssertTrue(gaps.isEmpty, "machine was down across the gap: not a monitoring gap")
    }

    // MARK: - Volume mount -> scan wiring (degraded scanner)

    func testVolumeMountWithUnavailableScannerRecordsSkippedScan() async throws {
        let storageOnly = DeviceDescriptor(
            deviceKey: "usb-loc-0x14300000", vid: 0x0951, pid: 0x1666,
            serial: "STICK01", vendorName: "Kingston", productName: "DataTraveler",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 0x06, usbProtocol: 0x50)],
            portPath: "20-3"
        )
        let events: [CollectorEvent] = [
            .attached(storageOnly),
            .volumeMounted(VolumeDescriptor(deviceKey: storageOnly.deviceKey,
                                            volumePath: "/Volumes/STICK",
                                            volumeName: "STICK", totalBytes: 1_000_000)),
        ]

        let (store, _) = try makeDB()
        // The mount scan is gated on policy `scanOnMount` (05); enable it so the
        // unavailable-engine path still records its skipped scan.
        try APIStore(store: store).setPolicyKey("scanOnMount", valueJSON: "true", actor: "test")
        let stateDir = makeTempStateDir()
        let discovery = EngineDiscovery(
            clamdSocketPath: "/nope.sock", clamdSocketLive: { _ in false },
            candidateExecutables: [:], searchDirs: [], fileExists: { _ in false }
        )
        let orchestrator = ScanOrchestrator(store: store, discovery: discovery,
                                            runner: ScanProcessRunner(), definitions: nil)
        let daemon = DaemonCore(
            store: store,
            source: FakeDeviceEventSource(events: events),
            stateDirectory: stateDir,
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: false),
            allowlist: Allowlist(patterns: []),
            scanOrchestrator: orchestrator,
            scanConfig: ScanConfig(timeout: 5, quarantineEnabled: true,
                                   definitionsWarnDays: 7,
                                   quarantineDirectory: stateDir + "/quarantine"),
            clock: { self.base },
            bootTime: { self.base.addingTimeInterval(-86_400) }
        )
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        let kinds = try ascendingEvents(store).map(\.kind)
        XCTAssertEqual(kinds, ["daemon.started", "device.attached", "volume.mounted", "scan.skipped"],
                       "got \(kinds)")
        let skipped = try XCTUnwrap(store.listEvents(filter: EventFilter(kind: "scan.skipped")).first)
        XCTAssertTrue(skipped.summary.contains("brew install clamav"),
                      "the skip records the install fix: \(skipped.summary)")
    }

    // MARK: - Mount scan: non-blocking + scanOnMount gate (C1)

    /// Path to a fake `clamscan` shell fixture (shared with ScanningTests).
    private func scanFixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PlugsightDaemonTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures/clamav/\(name)")
            .path
    }

    private func clamscanDiscovery(_ script: String) -> EngineDiscovery {
        EngineDiscovery(
            clamdSocketPath: "/nope.sock", clamdSocketLive: { _ in false },
            candidateExecutables: ["clamscan": script], searchDirs: [],
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// A plain storage stick (no hidden HID): mounts a volume, nothing to alert.
    private func storageStick(key: String) -> DeviceDescriptor {
        DeviceDescriptor(
            deviceKey: key, vid: 0x0951, pid: 0x1666,
            serial: "S-\(key)", vendorName: "Kingston", productName: "DataTraveler",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 0x06, usbProtocol: 0x50)],
            portPath: "20-9"
        )
    }

    /// Poll `condition` until true or the deadline; returns whether it became true.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return try condition()
    }

    private func makeMountDaemon(
        events: [CollectorEvent], discovery: EngineDiscovery, scanTimeout: TimeInterval,
        seedPolicy: ((APIStore) throws -> Void)? = nil
    ) throws -> (daemon: DaemonCore, store: EventStore, stateDir: String) {
        let (store, _) = try makeDB()
        try seedPolicy?(APIStore(store: store))
        let stateDir = makeTempStateDir()
        let orchestrator = ScanOrchestrator(store: store, discovery: discovery,
                                            runner: ScanProcessRunner(), definitions: nil)
        let daemon = DaemonCore(
            store: store,
            source: FakeDeviceEventSource(events: events),
            stateDirectory: stateDir,
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
            allowlist: Allowlist(patterns: []),
            scanOrchestrator: orchestrator,
            scanConfig: ScanConfig(timeout: scanTimeout, quarantineEnabled: true,
                                   definitionsWarnDays: 7,
                                   quarantineDirectory: stateDir + "/quarantine"),
            clock: { self.base },
            bootTime: { self.base.addingTimeInterval(-86_400) }
        )
        return (daemon, store, stateDir)
    }

    /// C1 (primary): a mount-triggered scan must NOT block the analyzer loop. With
    /// a scan that hangs, a device attached AFTER the mount is still processed
    /// promptly, and the analyzer loop returns while the scan is still running.
    /// Before the fix the scan ran inline on the analyzer loop, so the loop stalled
    /// for the whole scan (up to the timeout).
    func testMountScanDoesNotBlockAnalyzerLoop() async throws {
        let stick = storageStick(key: "usb-loc-0xMOUNT1")
        let laterKeyboard = DeviceDescriptor(
            deviceKey: "usb-loc-0xLATER", vid: 0x046D, pid: 0xC31C,
            serial: "KB-LATER", vendorName: "Logitech", productName: "K120",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0x01, usbProtocol: 0x01)],
            portPath: "20-8")
        let events: [CollectorEvent] = [
            .attached(stick),
            .volumeMounted(VolumeDescriptor(deviceKey: stick.deviceKey,
                                            volumePath: "/Volumes/STICK", volumeName: "STICK",
                                            totalBytes: 1_000_000)),
            .attached(laterKeyboard),
        ]
        // hang.sh sleeps 30s; the 5s config timeout bounds the background scan.
        let (daemon, store, _) = try makeMountDaemon(
            events: events, discovery: clamscanDiscovery(scanFixture("hang.sh")), scanTimeout: 5,
            seedPolicy: { try $0.setPolicyKey("scanOnMount", valueJSON: "true", actor: "test") })
        try daemon.start()
        defer { daemon.stop() }

        let startedAt = Date()
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()
        let loopElapsed = Date().timeIntervalSince(startedAt)

        // The loop returned WAY before the hanging scan could finish.
        XCTAssertLessThan(loopElapsed, 2.0,
                          "the analyzer loop must not wait for the mount scan (took \(loopElapsed)s)")

        let kinds = try ascendingEvents(store).map(\.kind)
        // The device attached AFTER the mount was processed by the loop…
        XCTAssertEqual(kinds.filter { $0 == "device.attached" }.count, 2,
                       "the post-mount attach must be processed; got \(kinds)")
        // …and the scan was initiated but has NOT finished (still running on the
        // background thread). Inline (pre-fix) execution would have appended
        // scan.finished before the second attach.
        XCTAssertTrue(kinds.contains("scan.started"), "the scan was initiated; got \(kinds)")
        XCTAssertFalse(kinds.contains("scan.finished"),
                       "the scan must still be running off the loop; got \(kinds)")
    }

    /// C1 (secondary, revised in Wave 1b): with policy `scanOnMount` explicitly
    /// disabled, a mount runs NO scan, but the decline is RECORDED as a
    /// `skipped` scan row so the UI can say why there is no scan. (The v1
    /// default is ON; this test turns it OFF to exercise the disabled path.)
    func testMountDoesNotScanWhenScanOnMountDisabled() async throws {
        let stick = storageStick(key: "usb-loc-0xMOUNT2")
        let events: [CollectorEvent] = [
            .attached(stick),
            .volumeMounted(VolumeDescriptor(deviceKey: stick.deviceKey,
                                            volumePath: "/Volumes/STICK", volumeName: "STICK",
                                            totalBytes: 1_000_000)),
        ]
        // Engine is available, but scanOnMount is turned off -> no scan.
        let (daemon, store, _) = try makeMountDaemon(
            events: events, discovery: clamscanDiscovery(scanFixture("clean.sh")), scanTimeout: 10,
            seedPolicy: { try $0.setPolicyKey("scanOnMount", valueJSON: "false", actor: "test") })
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        // Give any (erroneously) detached scan a chance to write, then assert.
        _ = waitUntil(timeout: 0.5) { false }
        let kinds = try ascendingEvents(store).map(\.kind)
        XCTAssertEqual(kinds, ["daemon.started", "device.attached", "volume.mounted", "scan.skipped"],
                       "scanOnMount=false must record WHY there is no scan; got \(kinds)")
        XCTAssertFalse(kinds.contains("scan.started"),
                       "no actual scan may run; got \(kinds)")
        // The skipped scan row carries the reason.
        let scan = try XCTUnwrap(APIStore(store: store).listScans().first)
        XCTAssertEqual(scan.state, "skipped")
        let skipped = try ascendingEvents(store).last { $0.kind == "scan.skipped" }
        XCTAssertTrue(try XCTUnwrap(skipped).summary.contains("Scanning on mount is off"),
                      "the reason is plain language; got \(String(describing: skipped?.summary))")
    }

    /// C1 (secondary): with policy `scanOnMount` enabled, a mount triggers a real
    /// scan that runs to completion (off the analyzer loop).
    func testMountScansWhenScanOnMountEnabled() async throws {
        let stick = storageStick(key: "usb-loc-0xMOUNT3")
        let events: [CollectorEvent] = [
            .attached(stick),
            .volumeMounted(VolumeDescriptor(deviceKey: stick.deviceKey,
                                            volumePath: "/Volumes/STICK", volumeName: "STICK",
                                            totalBytes: 1_000_000)),
        ]
        let (daemon, store, _) = try makeMountDaemon(
            events: events, discovery: clamscanDiscovery(scanFixture("clean.sh")), scanTimeout: 10,
            seedPolicy: { try $0.setPolicyKey("scanOnMount", valueJSON: "true", actor: "test") })
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        // scan.started is synchronous (on the loop); scan.finished lands async.
        let started = try ascendingEvents(store).map(\.kind)
        XCTAssertTrue(started.contains("scan.started"), "the scan was initiated; got \(started)")
        let finished = try waitUntil(timeout: 3) {
            try self.ascendingEvents(store).map(\.kind).contains("scan.finished")
        }
        XCTAssertTrue(finished, "the background mount scan must run to completion")
        let scan = try XCTUnwrap(APIStore(store: store).listScans().first)
        XCTAssertEqual(scan.state, "clean", "clean.sh yields a clean scan")
    }

    /// C1 (secondary, revised in Wave 1b): a `trusted` device is exempt from
    /// mount scanning (05), even when scanOnMount is enabled, and the decline
    /// is RECORDED as a `skipped` scan naming the reason.
    func testMountDoesNotScanTrustedDevice() async throws {
        let stick = storageStick(key: "usb-loc-0xTRUSTED")
        let events: [CollectorEvent] = [
            .attached(stick),
            .volumeMounted(VolumeDescriptor(deviceKey: stick.deviceKey,
                                            volumePath: "/Volumes/STICK", volumeName: "STICK",
                                            totalBytes: 1_000_000)),
        ]
        let (daemon, store, _) = try makeMountDaemon(
            events: events, discovery: clamscanDiscovery(scanFixture("clean.sh")), scanTimeout: 10,
            seedPolicy: { api in
                try api.setPolicyKey("scanOnMount", valueJSON: "true", actor: "test")
                // Mark the device trusted before it mounts (same identity key, so
                // the daemon's re-upsert on attach preserves the trusted tier).
                let up = try api.eventStore.upsertDevice(from: stick, at: self.base)
                _ = try api.setTrust(deviceID: up.deviceID, tier: "trusted", note: nil, actor: "test")
            })
        try daemon.start()
        defer { daemon.stop() }
        daemon.startEventFlow()
        await daemon.waitForEventFlowCompletion()

        _ = waitUntil(timeout: 0.5) { false }
        let kinds = try ascendingEvents(store).map(\.kind)
        XCTAssertFalse(kinds.contains("scan.started"),
                       "a trusted device is not scanned on mount; got \(kinds)")
        // The decline is recorded so the UI can say why there is no scan.
        let skipped = try ascendingEvents(store).last { $0.kind == "scan.skipped" }
        XCTAssertTrue(try XCTUnwrap(skipped).summary.contains("Device is trusted"),
                      "the skip names its reason; got \(String(describing: skipped?.summary))")
        let scan = try XCTUnwrap(APIStore(store: store).listScans().first)
        XCTAssertEqual(scan.state, "skipped")
    }

    // MARK: - Seed-DB boot (G)

    func testBootOptionsParseDefaultsSeedAndSocket() {
        let home = "/Users/example"
        let defaults = DaemonBootOptions.parse(arguments: ["plugsightd"], environment: [:], home: home)
        XCTAssertEqual(defaults.databasePath,
                       "/Users/example/Library/Application Support/Plugsight/plugsight.db")
        XCTAssertEqual(defaults.stateDirectory,
                       "/Users/example/Library/Application Support/Plugsight")
        XCTAssertFalse(defaults.seeded)

        let args = DaemonBootOptions.parse(
            arguments: ["plugsightd", "--seed", "/tmp/seed.db", "--socket", "/tmp/st8/plugsightd.sock"],
            environment: [:], home: home)
        XCTAssertEqual(args.databasePath, "/tmp/seed.db")
        XCTAssertEqual(args.stateDirectory, "/tmp/st8")
        XCTAssertTrue(args.seeded)

        let env = DaemonBootOptions.parse(
            arguments: ["plugsightd"],
            environment: ["PLUGSIGHT_SEED_DB": "/tmp/s.db", "PLUGSIGHT_STATE_DIR": "/tmp/dir"],
            home: home)
        XCTAssertEqual(env.databasePath, "/tmp/s.db")
        XCTAssertEqual(env.stateDirectory, "/tmp/dir")
        XCTAssertTrue(env.seeded)

        // CLI args take precedence over the environment.
        let both = DaemonBootOptions.parse(
            arguments: ["plugsightd", "--seed", "/tmp/arg.db"],
            environment: ["PLUGSIGHT_SEED_DB": "/tmp/env.db"],
            home: home)
        XCTAssertEqual(both.databasePath, "/tmp/arg.db")
    }

    func testSeededDaemonServesSeededDevicesOverTheSocket() throws {
        // Seed a device the way N9's test:roundtrip will, then boot against it.
        let (store, _) = try makeDB()
        _ = try store.upsertDevice(from: badUSB, at: base)

        let stateDir = makeTempStateDir()
        let daemon = DaemonCore(
            store: store,
            source: FakeDeviceEventSource(events: []),
            stateDirectory: stateDir,
            capabilities: Capabilities(inputMonitoring: false, endpointSecurity: false, clamav: false),
            allowlist: Allowlist(patterns: []),
            clock: { self.base },
            bootTime: { self.base.addingTimeInterval(-60) }
        )
        try daemon.start()
        defer { daemon.stop() }

        let client = try authedClient(daemon.server, name: "roundtrip", kind: "mcp")
        defer { client.close() }
        let result = try XCTUnwrap(client.call(id: 1, method: "devices.list").rpcResult)
        let devices = try XCTUnwrap(result["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0]["vidPid"] as? String, "1234:5678")
    }

    // MARK: - launchd agent plist (F)

    func testLaunchAgentPlistIsPresentAndWellFormed() throws {
        let here = URL(fileURLWithPath: #filePath)
        let plistURL = here
            .deletingLastPathComponent()   // PlugsightDaemonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("ops/launchd/com.plugsight.daemon.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.plugsight.daemon")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertNotNil(plist["BundleProgram"], "SMAppService.agent resolves BundleProgram in-bundle")
    }
}
