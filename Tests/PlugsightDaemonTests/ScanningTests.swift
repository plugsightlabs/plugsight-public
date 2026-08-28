// ScanningTests.swift
//
// N7 CI gate (docs/spec/05, 07). Every ClamAV-orchestration behavior is exercised
// against FAKE `clamscan` shell fixtures (Tests/Fixtures/clamav/*.sh) so nothing
// here needs a real engine, real signatures, or a real BadUSB device. The EICAR
// end-to-end against a real ClamAV install is a MANUAL release-checklist item, not
// part of this suite.
//
// Coverage map:
//   - engine discovery order + `unavailable` install fix
//   - verdict parsing (clean / infected / file list + signature names)
//   - exit-2 renders `failed`, NEVER `clean`
//   - definitions-age notice from freshclam DB timestamps
//   - report-only vs quarantined alert copy (honest containment language)
//   - quarantine move: sha-256 rename, sidecar, 0700 dir, no symlink follow
//   - read-only volume degrades to reported_only
//   - process runner: exit codes, timeout kills the process GROUP, cancel
//   - store extension: scan rows, findings, timeline events, alert row
//   - orchestrator: missing engine -> skipped event + scanner_unavailable error

import XCTest
import Foundation
import CryptoKit
@testable import PlugsightDaemon
import PlugsightCore

final class ScanningTests: XCTestCase {

    // MARK: - Fixtures

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PlugsightDaemonTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures/clamav/\(name)")
            .path
    }

    // MARK: - Engine discovery

    func testDiscoveryPrefersLiveClamdViaClamdscan() {
        let discovery = EngineDiscovery(
            clamdSocketPath: "/opt/homebrew/var/run/clamav/clamd.sock",
            clamdSocketLive: { _ in true },
            candidateExecutables: [
                "clamdscan": "/opt/homebrew/bin/clamdscan",
                "clamscan": "/opt/homebrew/bin/clamscan",
            ],
            fileExists: { _ in true }
        )
        XCTAssertEqual(
            discovery.resolve(),
            .clamdscan(executable: "/opt/homebrew/bin/clamdscan",
                       socket: "/opt/homebrew/var/run/clamav/clamd.sock")
        )
    }

    func testDiscoveryFallsBackToClamscanWhenNoDaemon() {
        let fake = fixture("clean.sh")
        let discovery = EngineDiscovery(
            clamdSocketPath: "/nope/clamd.sock",
            clamdSocketLive: { _ in false },
            candidateExecutables: ["clamscan": fake],
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        XCTAssertEqual(discovery.resolve(), .clamscan(executable: fake))
    }

    func testDiscoveryUnavailableCarriesInstallFix() {
        let discovery = EngineDiscovery(
            clamdSocketPath: "/nope/clamd.sock",
            clamdSocketLive: { _ in false },
            candidateExecutables: [:],
            fileExists: { _ in false }
        )
        guard case let .unavailable(installFix) = discovery.resolve() else {
            return XCTFail("expected .unavailable")
        }
        XCTAssertTrue(installFix.contains("brew install clamav"),
                      "install fix must name the brew command")
        XCTAssertTrue(installFix.lowercased().contains("freshclam"),
                      "install fix must name the freshclam first-run step")
    }

    // MARK: - Output parsing / verdicts

    func testParseCleanReportFromExitZero() {
        let stdout = """
        /Volumes/STICK/readme.txt: OK
        /Volumes/STICK/photo.jpg: OK
        """
        let report = ScanOutputParser.report(outcome: .exited(code: 0), stdout: stdout)
        XCTAssertEqual(report.state, .clean)
        XCTAssertEqual(report.findings, [])
        XCTAssertEqual(report.filesScanned, 2)
    }

    func testParseInfectedReportListsFilesAndSignatures() {
        let stdout = """
        /Volumes/STICK/invoice.pdf: OK
        /Volumes/STICK/payload.exe: Eicar-Test-Signature FOUND
        /Volumes/STICK/dropper.bin: Win.Trojan.Agent-12345 FOUND
        """
        let report = ScanOutputParser.report(outcome: .exited(code: 1), stdout: stdout)
        XCTAssertEqual(report.state, .infected)
        XCTAssertEqual(report.filesScanned, 3)
        XCTAssertEqual(report.findings, [
            ScanFinding(filePath: "/Volumes/STICK/payload.exe", signature: "Eicar-Test-Signature"),
            ScanFinding(filePath: "/Volumes/STICK/dropper.bin", signature: "Win.Trojan.Agent-12345"),
        ])
    }

    func testExitTwoRendersFailedNeverClean() {
        // Even if stdout somehow shows only OK lines, exit 2 is an engine error.
        let report = ScanOutputParser.report(
            outcome: .exited(code: 2),
            stdout: "/Volumes/STICK/readme.txt: OK\n"
        )
        XCTAssertEqual(report.state, .failed, "exit 2 must be failed")
        XCTAssertNotEqual(report.state, .clean, "exit 2 must never read as clean")
    }

    func testTimeoutAndCancelOutcomesMapToStates() {
        XCTAssertEqual(ScanOutputParser.report(outcome: .timedOut, stdout: "").state, .failed)
        XCTAssertEqual(ScanOutputParser.report(outcome: .canceled, stdout: "").state, .canceled)
    }

    // MARK: - Definitions age

    func testDefinitionsAgeNoticeWhenStale() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let twelveDaysAgo = now.addingTimeInterval(-12 * 86_400)
        let defs = DefinitionsAge(
            databaseDirectory: "/opt/homebrew/var/lib/clamav",
            mtime: { path in path.hasSuffix("daily.cld") ? twelveDaysAgo : nil }
        )
        XCTAssertEqual(defs.ageInDays(now: now), 12)
        XCTAssertEqual(defs.notice(now: now, warnDays: 7), "definitions 12 days old")
    }

    func testDefinitionsFreshGivesNoNotice() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        let defs = DefinitionsAge(
            databaseDirectory: "/db",
            mtime: { _ in threeDaysAgo }
        )
        XCTAssertEqual(defs.ageInDays(now: now), 3)
        XCTAssertNil(defs.notice(now: now, warnDays: 7))
    }

    func testDefinitionsUnknownWhenNoDatabase() {
        let defs = DefinitionsAge(databaseDirectory: "/db", mtime: { _ in nil })
        XCTAssertNil(defs.ageInDays(now: Date()))
        XCTAssertNil(defs.notice(now: Date(), warnDays: 7))
    }

    // MARK: - Alert copy (honest containment language)

    func testQuarantinedAlertCopyNamesFileSignatureAndAction() {
        let copy = ScanAlertCopy.infected(
            file: "/Volumes/STICK/payload.exe",
            signature: "Eicar-Test-Signature",
            action: .quarantined
        )
        XCTAssertTrue(copy.contains("payload.exe"))
        XCTAssertTrue(copy.contains("Eicar-Test-Signature"))
        XCTAssertTrue(copy.lowercased().contains("quarantine"))
    }

    func testReportOnlyAlertCopyIsHonestAboutNoContainment() {
        let copy = ScanAlertCopy.infected(
            file: "/Volumes/STICK/payload.exe",
            signature: "Eicar-Test-Signature",
            action: .reportedOnly
        )
        XCTAssertTrue(copy.contains("payload.exe"))
        XCTAssertTrue(copy.contains("Eicar-Test-Signature"))
        // Must say report-only, and must NOT claim it was contained/quarantined.
        XCTAssertTrue(copy.lowercased().contains("report"),
                      "report-only copy must say so")
        XCTAssertFalse(copy.lowercased().contains("moved to quarantine"),
                       "report-only copy must not claim containment")
    }

    // MARK: - Quarantine

    /// A unique temp workspace, cleaned up after each quarantine test.
    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugsight-n7-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testQuarantineMovesFileToSha256WithSidecarIn0700Dir() throws {
        let root = try makeTempDir("quar")
        defer { try? FileManager.default.removeItem(at: root) }

        let volume = root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let content = Data("EICAR-PAYLOAD-BYTES".utf8)
        let source = volume.appendingPathComponent("payload.exe")
        try content.write(to: source)

        let quarantineDir = root.appendingPathComponent("quarantine", isDirectory: true).path
        let quarantine = Quarantine(directory: quarantineDir)

        let result = try quarantine.contain(
            filePath: source.path,
            signature: "Eicar-Test-Signature",
            deviceID: "dev_abc",
            scanID: "scn_123",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let expectedHex = sha256Hex(content)
        guard case let .quarantined(path) = result else {
            return XCTFail("expected .quarantined, got \(result)")
        }
        XCTAssertEqual((path as NSString).lastPathComponent, expectedHex,
                       "quarantined file is renamed to the sha-256 of its contents")

        // The file moved: gone from the volume, present (with same bytes) in quarantine.
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "source is removed from the volume after containment")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), content)

        // Sidecar next to it carries the provenance the dossier needs.
        let sidecarPath = path + ".json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath), "sidecar JSON exists")
        let sidecar = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: sidecarPath))) as? [String: Any]
        XCTAssertEqual(sidecar?["original_path"] as? String, source.path)
        XCTAssertEqual(sidecar?["device"] as? String, "dev_abc")
        XCTAssertEqual(sidecar?["scan_id"] as? String, "scn_123")
        XCTAssertEqual(sidecar?["signature"] as? String, "Eicar-Test-Signature")

        // Quarantine directory is 0700.
        let perms = try FileManager.default.attributesOfItem(atPath: quarantineDir)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o700, "quarantine dir must be 0700")
    }

    func testQuarantineNeverFollowsSymlinkToDestroyTarget() throws {
        let root = try makeTempDir("symlink")
        defer { try? FileManager.default.removeItem(at: root) }

        // A precious real file OUTSIDE the volume.
        let secretDir = root.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secret = secretDir.appendingPathComponent("id_rsa")
        try Data("TOP-SECRET-KEY".utf8).write(to: secret)

        // The volume plants a symlink named like an infected file, pointing at the secret.
        let volume = root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let link = volume.appendingPathComponent("payload.exe")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: secret.path)

        let quarantineDir = root.appendingPathComponent("quarantine", isDirectory: true).path
        let quarantine = Quarantine(directory: quarantineDir)

        let result = try quarantine.contain(
            filePath: link.path,
            signature: "Eicar-Test-Signature",
            deviceID: "dev_abc",
            scanID: "scn_123",
            now: Date()
        )

        // The symlink target must be untouched — we never follow the link to move it out.
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path),
                      "the symlink target must NOT be moved or destroyed")
        XCTAssertEqual(try Data(contentsOf: secret), Data("TOP-SECRET-KEY".utf8))

        // The outcome is honest: reported-only for the unsafe-symlink reason.
        XCTAssertEqual(result, .reportedOnly(reason: .unsafeSymlink))
    }

    func testQuarantineReadOnlyVolumeDegradesToReportedOnly() throws {
        let root = try makeTempDir("readonly")
        // Restore perms before cleanup so tearDown can delete the tree.
        defer {
            let ro = root.appendingPathComponent("volume").path
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro)
            try? FileManager.default.removeItem(at: root)
        }

        let volume = root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let content = Data("EICAR-PAYLOAD-BYTES".utf8)
        let source = volume.appendingPathComponent("payload.exe")
        try content.write(to: source)
        // Make the volume directory read-only: the file can be read (hashed) but
        // cannot be renamed/removed out of it — modelling a read-only USB volume.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: volume.path)

        let quarantineDir = root.appendingPathComponent("quarantine", isDirectory: true).path
        let quarantine = Quarantine(directory: quarantineDir)

        let result = try quarantine.contain(
            filePath: source.path,
            signature: "Eicar-Test-Signature",
            deviceID: "dev_abc",
            scanID: "scn_123",
            now: Date()
        )

        XCTAssertEqual(result, .reportedOnly(reason: .readOnlyVolume))
        // The file stays put (it could not be contained), and the honest alert copy says so.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "a report-only finding leaves the file in place")
        let copy = ScanAlertCopy.infected(file: source.path, signature: "Eicar-Test-Signature",
                                           action: .reportedOnly, reason: .readOnlyVolume)
        XCTAssertTrue(copy.lowercased().contains("read-only"))
    }

    // MARK: - Process runner (against the fake clamscan fixtures)

    /// Poll until both pids are gone (ESRCH) or the deadline passes.
    private func waitUntilDead(_ pids: [pid_t], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let anyAlive = pids.contains { kill($0, 0) == 0 }
            if !anyAlive { return true }
            usleep(20_000)
        }
        return !pids.contains { kill($0, 0) == 0 }
    }

    func testRunnerCleanExitZeroWithVerdictLines() {
        let result = ScanProcessRunner().run(
            executable: fixture("clean.sh"), arguments: [], timeout: 10
        )
        XCTAssertEqual(result.outcome, .exited(code: 0))
        XCTAssertTrue(result.stdout.contains(": OK"))
    }

    func testRunnerInfectedExitsOneWithFoundLine() {
        let result = ScanProcessRunner().run(
            executable: fixture("infected.sh"), arguments: [], timeout: 10
        )
        XCTAssertEqual(result.outcome, .exited(code: 1))
        XCTAssertTrue(result.stdout.contains("FOUND"))
    }

    func testRunnerEngineErrorExitsTwo() {
        let result = ScanProcessRunner().run(
            executable: fixture("error.sh"), arguments: [], timeout: 10
        )
        XCTAssertEqual(result.outcome, .exited(code: 2))
        XCTAssertTrue(result.stderr.contains("ERROR"))
    }

    func testRunnerTimeoutKillsTheWholeProcessGroup() throws {
        let pidFile = try makeTempDir("pids").appendingPathComponent("pids.txt")
        let result = ScanProcessRunner().run(
            executable: fixture("slow.sh"), arguments: [pidFile.path], timeout: 0.5
        )
        XCTAssertEqual(result.outcome, .timedOut, "a scan past its timeout is timed out")

        // slow.sh recorded its own pid and its backgrounded sleep's pid. If the
        // runner had killed only the direct child, the sleep would survive.
        let recorded = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .compactMap { pid_t($0) }
        XCTAssertEqual(recorded.count, 2, "fixture must record both pids")
        XCTAssertTrue(waitUntilDead(recorded, timeout: 3),
                      "the whole process group (sh + sleep) must be dead after timeout")
    }

    func testRunnerCancelRecordsCanceledAndKillsGroup() throws {
        let pidFile = try makeTempDir("pids").appendingPathComponent("pids.txt")
        let cancel = CancelToken()
        // Cancel as soon as the child has started and recorded its pids (rather
        // than after a fixed delay, which is flaky under suite load). The long
        // timeout guarantees only the cancel can end the run.
        DispatchQueue.global().async {
            for _ in 0..<2000 where !FileManager.default.fileExists(atPath: pidFile.path) {
                usleep(5_000)
            }
            cancel.cancel()
        }
        let result = ScanProcessRunner().run(
            executable: fixture("slow.sh"), arguments: [pidFile.path], timeout: 30, cancel: cancel
        )
        XCTAssertEqual(result.outcome, .canceled)

        let recorded = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .compactMap { pid_t($0) }
        XCTAssertTrue(waitUntilDead(recorded, timeout: 3),
                      "cancel must kill the whole process group")
    }

    // MARK: - Store extension (EventStore+Scans)

    /// A fresh on-disk store (my scan extension opens a second connection by path,
    /// so a real file — not :memory: — is required).
    private func makeStore() throws -> (EventStore, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugsight-n7-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("plugsight.sqlite").path
        return (try EventStore(path: path), path)
    }

    private func makeDevice(_ store: EventStore) throws -> String {
        try store.upsertDevice(from: DeviceDescriptor(
            deviceKey: "k", vid: 0x090C, pid: 0x1000, serial: "SN12345678",
            vendorName: "USB", productName: "DISK 2.0",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 8, usbSubclass: 6, usbProtocol: 80)],
            portPath: "1-1"
        )).deviceID
    }

    func testCreateScanWritesRunningRowAndStartedEvent() throws {
        let (store, path) = try makeStore()
        let device = try makeDevice(store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let scanID = try store.createScan(
            deviceID: device, volumePath: "/Volumes/STICK",
            engine: "clamscan", defsAgeDays: 3, startedBy: "system",
            startedSummary: "Scanning “STICK” with clamscan…", at: now
        )
        XCTAssertTrue(scanID.hasPrefix("scn_"))

        let row = try store.scanRow(id: scanID)
        XCTAssertEqual(row?.state, "running")
        XCTAssertEqual(row?.engine, "clamscan")
        XCTAssertEqual(row?.deviceID, device)
        XCTAssertEqual(row?.defsAgeDays, 3)
        XCTAssertNil(row?.finishedAt)

        let started = try store.listEvents(filter: EventFilter(kind: "scan.started"))
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.severity, "info")
        XCTAssertEqual(started.first?.deviceID, device)
    }

    func testUpdateScanRecordsTerminalStateAndFinishedEvent() throws {
        let (store, path) = try makeStore()
        let device = try makeDevice(store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scanID = try store.createScan(
            deviceID: device, volumePath: "/Volumes/STICK",
            engine: "clamscan", defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning…", at: now
        )

        try store.updateScan(
            id: scanID, state: "infected", filesScanned: 42,
            finishedSummary: "Found 1 infected file on “STICK”.", deviceID: device,
            at: now.addingTimeInterval(5)
        )

        let row = try store.scanRow(id: scanID)
        XCTAssertEqual(row?.state, "infected")
        XCTAssertEqual(row?.filesScanned, 42)
        XCTAssertNotNil(row?.finishedAt)

        let finished = try store.listEvents(filter: EventFilter(kind: "scan.finished"))
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.severity, "info")
    }

    func testInsertFindingWritesRow() throws {
        let (store, path) = try makeStore()
        let device = try makeDevice(store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scanID = try store.createScan(
            deviceID: device, volumePath: "/Volumes/STICK",
            engine: "clamscan", defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning…", at: now
        )

        try store.insertScanFinding(
            scanID: scanID,
            filePath: "/Volumes/STICK/payload.exe", signature: "Eicar-Test-Signature",
            action: "quarantined",
            quarantinePath: "/quarantine/deadbeef"
        )

        let findings = try store.scanFindingRows(scanID: scanID)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.filePath, "/Volumes/STICK/payload.exe")
        XCTAssertEqual(findings.first?.signature, "Eicar-Test-Signature")
        XCTAssertEqual(findings.first?.action, "quarantined")
        XCTAssertEqual(findings.first?.quarantinePath, "/quarantine/deadbeef")
    }

    func testRaiseScanAlertWritesAlertRowAndRaisedEvent() throws {
        let (store, path) = try makeStore()
        let device = try makeDevice(store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let alertID = try store.raiseScanAlert(
            deviceID: device, severity: "critical",
            summary: "Infected file “payload.exe” (Eicar-Test-Signature) was moved to quarantine.",
            why: "ClamAV signature match on a mounted USB volume.", at: now
        )
        XCTAssertTrue(alertID.hasPrefix("alr_"))

        let alerts = try store.scanAlertRows()
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.id, alertID)
        XCTAssertEqual(alerts.first?.rule, "scan_finding")
        XCTAssertEqual(alerts.first?.severity, "critical")
        XCTAssertEqual(alerts.first?.state, "active")

        // The timeline event references the alert row.
        let raised = try store.listEvents(filter: EventFilter(kind: "alert.raised"))
        XCTAssertEqual(raised.count, 1)
        XCTAssertEqual(raised.first?.alertID, alertID)
        XCTAssertEqual(raised.first?.severity, "critical")
    }

    func testRecordSkippedScanWritesSkippedRowAndEvent() throws {
        let (store, path) = try makeStore()
        let device = try makeDevice(store)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let scanID = try store.recordSkippedScan(
            deviceID: device, volumePath: "/Volumes/STICK",
            engine: "none", startedBy: "system",
            skippedSummary: "Scan skipped: ClamAV is not installed.", at: now
        )
        XCTAssertTrue(scanID.hasPrefix("scn_"))

        let row = try store.scanRow(id: scanID)
        XCTAssertEqual(row?.state, "skipped")
        XCTAssertNotNil(row?.finishedAt, "a skipped scan is already finished")

        let skipped = try store.listEvents(filter: EventFilter(kind: "scan.skipped"))
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.severity, "info")
    }

    // MARK: - Orchestrator (end to end, on fakes)

    private func unavailableDiscovery() -> EngineDiscovery {
        EngineDiscovery(
            clamdSocketPath: "/nope.sock", clamdSocketLive: { _ in false },
            candidateExecutables: [:], searchDirs: [], fileExists: { _ in false }
        )
    }

    private func clamscanDiscovery(_ script: String) -> EngineDiscovery {
        EngineDiscovery(
            clamdSocketPath: "/nope.sock", clamdSocketLive: { _ in false },
            candidateExecutables: ["clamscan": script], searchDirs: [],
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    private func config(quarantineDir: String, quarantine: Bool = true) -> ScanConfig {
        ScanConfig(timeout: 10, quarantineEnabled: quarantine,
                   definitionsWarnDays: 7, quarantineDirectory: quarantineDir)
    }

    func testMissingEngineRecordsSkippedAndThrowsScannerUnavailable() throws {
        let (store, path) = try makeStore()
        let device = try makeDevice(store)
        let orchestrator = ScanOrchestrator(
            store: store, discovery: unavailableDiscovery(),
            runner: ScanProcessRunner(), definitions: nil
        )
        let request = ScanRequest(deviceID: device, volumePath: "/Volumes/STICK", startedBy: "system")

        XCTAssertThrowsError(try orchestrator.scan(request, config: config(quarantineDir: "/q"))) { error in
            guard case let ScanError.scannerUnavailable(fix) = error else {
                return XCTFail("expected .scannerUnavailable, got \(error)")
            }
            XCTAssertTrue(fix.contains("brew install clamav"))
        }

        // A skipped scan is still recorded honestly, with its timeline event.
        let skipped = try store.listEvents(filter: EventFilter(kind: "scan.skipped"))
        XCTAssertEqual(skipped.count, 1)
        let alerts = try store.scanAlertRows()
        XCTAssertTrue(alerts.isEmpty, "a skipped scan raises no alert")
    }

    func testCleanScanEndToEndRecordsCleanWithDefinitionsNotice() throws {
        let (store, path) = try makeStore()
        let device = try makeDevice(store)
        let quarantineDir = try makeTempDir("q").path
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twelveDaysAgo = now.addingTimeInterval(-12 * 86_400)
        let defs = DefinitionsAge(databaseDirectory: "/db", mtime: { _ in twelveDaysAgo })

        let orchestrator = ScanOrchestrator(
            store: store, discovery: clamscanDiscovery(fixture("clean.sh")),
            runner: ScanProcessRunner(), definitions: defs, clock: { now }
        )
        let outcome = try orchestrator.scan(
            ScanRequest(deviceID: device, volumePath: "/Volumes/STICK", startedBy: "system"),
            config: config(quarantineDir: quarantineDir)
        )

        XCTAssertEqual(outcome.state, .clean)
        let row = try store.scanRow(id: outcome.scanID)
        XCTAssertEqual(row?.state, "clean")
        XCTAssertEqual(row?.defsAgeDays, 12, "stale definitions age is recorded on the scan row")

        // The finished summary carries the stale-definitions notice.
        let finished = try store.listEvents(filter: EventFilter(kind: "scan.finished"))
        XCTAssertEqual(finished.count, 1)
        XCTAssertTrue(finished.first?.summary.contains("definitions 12 days old") ?? false,
                      "a clean scan on stale defs still says the defs were stale")
    }

    func testInfectedScanEndToEndQuarantinesAndRaisesCriticalAlert() throws {
        let (store, path) = try makeStore()
        let device = try makeDevice(store)

        // A real volume with a real infected file the fake clamscan will report.
        let volume = try makeTempDir("vol")
        defer { try? FileManager.default.removeItem(at: volume) }
        let payload = volume.appendingPathComponent("payload.exe")
        try Data("EICAR-BYTES".utf8).write(to: payload)
        let quarantineDir = volume.appendingPathComponent("../quarantine").path

        let orchestrator = ScanOrchestrator(
            store: store, discovery: clamscanDiscovery(fixture("infected-arg.sh")),
            runner: ScanProcessRunner(), definitions: nil
        )
        let outcome = try orchestrator.scan(
            ScanRequest(deviceID: device, volumePath: volume.path, startedBy: "system"),
            config: config(quarantineDir: quarantineDir)
        )

        XCTAssertEqual(outcome.state, .infected)
        XCTAssertEqual(outcome.findingActions, [.quarantined])

        // Finding row records the containment + quarantine path.
        let findings = try store.scanFindingRows(scanID: outcome.scanID)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.action, "quarantined")
        XCTAssertNotNil(findings.first?.quarantinePath)

        // The real file was contained: gone from the volume, present in quarantine.
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: findings.first!.quarantinePath!))

        // A critical scan_finding alert names the file, signature, and action.
        let alerts = try store.scanAlertRows()
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.severity, "critical")
        XCTAssertEqual(alerts.first?.rule, "scan_finding")
        XCTAssertTrue(alerts.first?.summary.contains("payload.exe") ?? false)
        XCTAssertTrue(alerts.first?.summary.contains("Eicar-Test-Signature") ?? false)
        XCTAssertTrue(alerts.first?.summary.lowercased().contains("quarantine") ?? false)
    }
}
