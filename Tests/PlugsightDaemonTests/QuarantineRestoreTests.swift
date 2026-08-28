// QuarantineRestoreTests.swift  (NQR — owner ruling D6)
//
// The 19th capability: full agent+human parity on un-quarantining. These tests
// cover the three layers of the restore path RED-first:
//   1. the MOVER (pure filesystem, reverse of N7's contain): moves a quarantined
//      file back to its original path, empties the slot, never follows a symlink;
//   2. the STORE (EventStore+Quarantine, path-keyed): finds the quarantine record
//      by its sha-256 id and appends the `quarantine.restored` event;
//   3. the API method `quarantine.restore` over the real UDS server: confirm gate,
//      not_found / conflict errors, and the explicit-risk sentence in the result.
//
// Fixtures are built by running N7's real `Quarantine.contain` so the sha-256 name
// and sidecar are exactly what the daemon produces in production.

import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class QuarantineRestoreTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeTempDir(_ tag: String = "nqr") throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/\(tag)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A genuine quarantine slot: an infected file is planted on a "volume" and
    /// contained by N7's mover, yielding the sha-256-named file + sidecar. Returns
    /// the quarantine directory, the id (sha-256 leaf), and the original path.
    private struct Fixture {
        let quarantineDir: String
        let quarantineId: String
        let originalPath: String
    }

    private func makeQuarantineFixture(
        signature: String = "Eicar-Test-Signature",
        deviceID: String? = nil,
        scanID: String = "scn_fixture",
        in root: URL
    ) throws -> Fixture {
        let volume = root.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let source = volume.appendingPathComponent("invoice.pdf")
        try "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR".write(to: source, atomically: true, encoding: .utf8)

        let quarantineDir = root.appendingPathComponent("quarantine").path
        let mover = Quarantine(directory: quarantineDir)
        let result = try mover.contain(filePath: source.path, signature: signature,
                                       deviceID: deviceID, scanID: scanID)
        guard case let .quarantined(qpath) = result else {
            throw XCTSkip("fixture did not quarantine")
        }
        let id = (qpath as NSString).lastPathComponent
        return Fixture(quarantineDir: quarantineDir, quarantineId: id, originalPath: source.path)
    }

    // MARK: - (a) Mover

    func testRestoreMovesFileBackAndEmptiesSlot() throws {
        let root = try makeTempDir("restore-move")
        let fx = try makeQuarantineFixture(in: root)

        let quarantineFile = (fx.quarantineDir as NSString).appendingPathComponent(fx.quarantineId)
        let sidecar = quarantineFile + ".json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.originalPath),
                       "the source was moved into quarantine by contain")

        let restorer = QuarantineRestore(directory: fx.quarantineDir)
        let outcome = try restorer.restore(quarantineId: fx.quarantineId)

        // The file is back at its original location (canonicalized).
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.originalPath),
                      "file restored to its original path")
        XCTAssertEqual((outcome.originalPath as NSString).lastPathComponent, "invoice.pdf")
        XCTAssertEqual(outcome.signature, "Eicar-Test-Signature")
        // The quarantine slot is emptied: neither the file nor the sidecar remain.
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineFile),
                       "quarantine file removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar),
                       "sidecar removed")
    }

    func testUnknownIdMoverThrowsNotFound() throws {
        let root = try makeTempDir("restore-unknown")
        let quarantineDir = root.appendingPathComponent("quarantine").path
        try FileManager.default.createDirectory(atPath: quarantineDir, withIntermediateDirectories: true)
        let restorer = QuarantineRestore(directory: quarantineDir)
        XCTAssertThrowsError(try restorer.restore(quarantineId: "deadbeef")) { err in
            XCTAssertEqual(err as? RestoreError, .notFound)
        }
    }

    func testRestoreRefusesSymlinkedDestination() throws {
        let root = try makeTempDir("restore-symlink")
        let fx = try makeQuarantineFixture(in: root)

        // The attacker replaces the original location with a symlink pointing at a
        // precious file. Restoring must NOT follow it and clobber the target.
        let secretDir = root.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secret = secretDir.appendingPathComponent("passwords.txt")
        try "TOP SECRET".write(to: secret, atomically: true, encoding: .utf8)
        // Original path parent still exists (the volume); plant a symlink at the leaf.
        try FileManager.default.createSymbolicLink(atPath: fx.originalPath, withDestinationPath: secret.path)

        let restorer = QuarantineRestore(directory: fx.quarantineDir)
        XCTAssertThrowsError(try restorer.restore(quarantineId: fx.quarantineId)) { err in
            guard case .unsafeDestination = (err as? RestoreError) else {
                return XCTFail("expected unsafeDestination, got \(err)")
            }
        }
        // The secret is untouched and the quarantine file is still there (not moved).
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "TOP SECRET")
        let quarantineFile = (fx.quarantineDir as NSString).appendingPathComponent(fx.quarantineId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineFile),
                      "quarantine file left in place when restore refused")
    }

    func testRestoreRefusesWhenDestinationAlreadyExists() throws {
        let root = try makeTempDir("restore-exists")
        let fx = try makeQuarantineFixture(in: root)
        // Something already sits at the original path.
        try "different".write(toFile: fx.originalPath, atomically: true, encoding: .utf8)

        let restorer = QuarantineRestore(directory: fx.quarantineDir)
        XCTAssertThrowsError(try restorer.restore(quarantineId: fx.quarantineId)) { err in
            guard case .destinationExists = (err as? RestoreError) else {
                return XCTFail("expected destinationExists, got \(err)")
            }
        }
    }

    // MARK: - (d) Store

    func testQuarantineFindingLookupByShaId() throws {
        let root = try makeTempDir("store-find")
        let db = try makeTestDB(inDir: root.path)
        let scan = try db.api.insertScan(deviceID: nil, volumePath: "/Volumes/USB",
                                         engine: "clamdscan", startedBy: "ui")
        let fx = try makeQuarantineFixture(scanID: scan.id, in: root)
        let quarantineFile = (fx.quarantineDir as NSString).appendingPathComponent(fx.quarantineId)
        try db.api.seedFinding(scanID: scan.id, filePath: fx.originalPath,
                               signature: "Eicar-Test-Signature", action: "quarantined",
                               quarantinePath: quarantineFile)

        let snap = try db.event.quarantineFinding(quarantineId: fx.quarantineId)
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.scanID, scan.id)
        XCTAssertEqual(snap?.filePath, fx.originalPath)
        XCTAssertEqual(snap?.signature, "Eicar-Test-Signature")

        // An unknown id resolves to nil (the API turns that into not_found).
        XCTAssertNil(try db.event.quarantineFinding(quarantineId: "nope"))
    }

    func testAppendQuarantineRestoredEventRecordsActorAndPath() throws {
        let root = try makeTempDir("store-event")
        let db = try makeTestDB(inDir: root.path)
        let event = try db.event.appendQuarantineRestoredEvent(
            deviceID: nil, actor: "mcp:claude-code",
            summary: "Restored 'invoice.pdf' from quarantine (flagged Eicar-Test-Signature) — by mcp:claude-code.",
            detail: "{\"v\":1,\"original_path\":\"/Volumes/USB/invoice.pdf\"}")
        XCTAssertEqual(event.kind, "quarantine.restored")
        XCTAssertEqual(event.actor, "mcp:claude-code")
        XCTAssertTrue(event.summary.contains("invoice.pdf"))

        let events = try db.event.quarantineRestoredEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, "quarantine.restored")
        XCTAssertTrue(events.first?.detail.contains("/Volumes/USB/invoice.pdf") ?? false)
    }

    // MARK: - (b/c) API method over the real UDS server

    func testRestoreOverAPIReturnsRiskSentenceAndMovesFile() throws {
        let root = try makeTempDir("api-restore")
        let db = try makeTestDB(inDir: root.path)
        let scan = try db.api.insertScan(deviceID: nil, volumePath: "/Volumes/USB",
                                         engine: "clamdscan", startedBy: "ui")
        let fx = try makeQuarantineFixture(scanID: scan.id, in: root)
        let quarantineFile = (fx.quarantineDir as NSString).appendingPathComponent(fx.quarantineId)
        try db.api.seedFinding(scanID: scan.id, filePath: fx.originalPath,
                               signature: "Eicar-Test-Signature", action: "quarantined",
                               quarantinePath: quarantineFile)

        let stateDir = makeTempStateDir()
        let server = try APIServer(databasePath: db.path, stateDirectory: stateDir,
                                   daemonVersion: "1.0.0",
                                   capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
                                   quarantineDirectory: fx.quarantineDir)
        try server.start()
        defer { server.stop() }
        let client = try authedClient(server, name: "claude-code", kind: "mcp")
        defer { client.close() }

        let resp = try client.call(id: 1, method: "quarantine.restore",
                                   params: ["quarantineId": fx.quarantineId, "confirm": true])
        let result = try XCTUnwrap(resp.rpcResult, "expected a result, got \(resp)")
        XCTAssertEqual(result["state"] as? String, "restored")
        let risk = result["risk"] as? String ?? ""
        XCTAssertTrue(risk.contains("only do this if you are certain it is a false positive"),
                      "the explicit-risk sentence rides in the success result; got '\(risk)'")
        XCTAssertEqual(result["signature"] as? String, "Eicar-Test-Signature")
        // The file is really back.
        let restoredPath = result["originalPath"] as? String ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredPath))

        // The quarantine.restored event was appended (actor = mcp:claude-code).
        let events = try db.event.quarantineRestoredEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.actor, "mcp:claude-code")
        XCTAssertTrue(events.first?.summary.contains("invoice.pdf") ?? false)
    }

    func testMissingConfirmReturnsInvalidParams() throws {
        let root = try makeTempDir("api-noconfirm")
        let db = try makeTestDB(inDir: root.path)
        let fx = try makeQuarantineFixture(in: root)
        let stateDir = makeTempStateDir()
        let server = try APIServer(databasePath: db.path, stateDirectory: stateDir,
                                   daemonVersion: "1.0.0",
                                   capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
                                   quarantineDirectory: fx.quarantineDir)
        try server.start()
        defer { server.stop() }
        let client = try authedClient(server, name: "claude-code", kind: "mcp")
        defer { client.close() }

        let resp = try client.call(id: 1, method: "quarantine.restore",
                                   params: ["quarantineId": fx.quarantineId])
        let error = try XCTUnwrap(resp.rpcError, "expected an error, got \(resp)")
        let data = error["data"] as? [String: Any]
        XCTAssertEqual(data?["kind"] as? String, "invalid_params")
        let message = (error["message"] as? String ?? "").lowercased()
        XCTAssertTrue(message.contains("confirm"), "message must mention confirm")
        XCTAssertTrue(message.contains("deliberate"), "message must explain it is a deliberate act")

        // Nothing was restored: the quarantine slot is intact.
        let quarantineFile = (fx.quarantineDir as NSString).appendingPathComponent(fx.quarantineId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineFile))
    }

    func testUnknownIdReturnsNotFound() throws {
        let root = try makeTempDir("api-unknown")
        let db = try makeTestDB(inDir: root.path)
        let fx = try makeQuarantineFixture(in: root)
        let stateDir = makeTempStateDir()
        let server = try APIServer(databasePath: db.path, stateDirectory: stateDir,
                                   daemonVersion: "1.0.0",
                                   capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
                                   quarantineDirectory: fx.quarantineDir)
        try server.start()
        defer { server.stop() }
        let client = try authedClient(server, name: "claude-code", kind: "mcp")
        defer { client.close() }

        let resp = try client.call(id: 1, method: "quarantine.restore",
                                   params: ["quarantineId": "deadbeef", "confirm": true])
        let error = try XCTUnwrap(resp.rpcError, "expected an error, got \(resp)")
        let data = error["data"] as? [String: Any]
        XCTAssertEqual(data?["kind"] as? String, "not_found")
    }

    func testAlreadyRestoredReturnsConflict() throws {
        let root = try makeTempDir("api-already")
        let db = try makeTestDB(inDir: root.path)
        let scan = try db.api.insertScan(deviceID: nil, volumePath: "/Volumes/USB",
                                         engine: "clamdscan", startedBy: "ui")
        let fx = try makeQuarantineFixture(scanID: scan.id, in: root)
        let quarantineFile = (fx.quarantineDir as NSString).appendingPathComponent(fx.quarantineId)
        try db.api.seedFinding(scanID: scan.id, filePath: fx.originalPath,
                               signature: "Eicar-Test-Signature", action: "quarantined",
                               quarantinePath: quarantineFile)

        let stateDir = makeTempStateDir()
        let server = try APIServer(databasePath: db.path, stateDirectory: stateDir,
                                   daemonVersion: "1.0.0",
                                   capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
                                   quarantineDirectory: fx.quarantineDir)
        try server.start()
        defer { server.stop() }
        let client = try authedClient(server, name: "claude-code", kind: "mcp")
        defer { client.close() }

        // First restore succeeds.
        let first = try client.call(id: 1, method: "quarantine.restore",
                                    params: ["quarantineId": fx.quarantineId, "confirm": true])
        XCTAssertNotNil(first.rpcResult, "first restore should succeed, got \(first)")

        // Second restore: the slot is empty (already restored) — conflict, with the
        // state riding in data.
        let second = try client.call(id: 2, method: "quarantine.restore",
                                     params: ["quarantineId": fx.quarantineId, "confirm": true])
        let error = try XCTUnwrap(second.rpcError, "expected a conflict, got \(second)")
        let data = error["data"] as? [String: Any]
        XCTAssertEqual(data?["kind"] as? String, "conflict")
        XCTAssertNotNil(data?["state"], "conflict must carry the state in data")
    }
}
