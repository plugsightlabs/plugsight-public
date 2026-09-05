// StoreHygieneTests.swift
//
// Store-level hygiene behaviors (Wave 1b):
//   1. Orphaned `running` scans (a daemon died mid-scan) reconcile to `failed`
//      with an honest scan.finished event carrying the reason.
//   2. Retention pruning also trims scan rows (and their findings) older than
//      the retention window, not just events + score snapshots.
//   3. The one-time cleanup deletes historical `failed` scan rows for internal
//      system volumes (the pre-ddcb42a "Scan of xarts failed" junk).

import XCTest
import Foundation
@testable import PlugsightCore

final class StoreHygieneTests: XCTestCase {

    private func makeStore() throws -> EventStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugsight-hygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("plugsight.sqlite").path
        return try EventStore(path: path)
    }

    private let base = Date(timeIntervalSince1970: 1_755_000_000)

    // MARK: - 1. Orphaned running scans

    func testFailOrphanedRunningScansMarksRunningRowsFailedAndAppendsEvents() throws {
        let store = try makeStore()
        let orphanA = try store.createScan(
            deviceID: nil, volumePath: "/Volumes/STICK", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning STICK", at: base)
        let orphanB = try store.createScan(
            deviceID: nil, volumePath: "/Volumes/OTHER", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning OTHER", at: base.addingTimeInterval(1))
        // A terminal scan must be left alone.
        let done = try store.createScan(
            deviceID: nil, volumePath: "/Volumes/DONE", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning DONE", at: base.addingTimeInterval(2))
        try store.updateScan(id: done, state: "clean", filesScanned: 3,
                             finishedSummary: "Scan finished: clean.", deviceID: nil,
                             at: base.addingTimeInterval(3))

        let now = base.addingTimeInterval(60)
        let reconciled = try store.failOrphanedRunningScans(reason: "Interrupted by a restart", at: now)
        XCTAssertEqual(reconciled, 2)

        let a = try XCTUnwrap(store.scanRow(id: orphanA))
        XCTAssertEqual(a.state, "failed")
        XCTAssertNotNil(a.finishedAt, "an orphaned scan gets a finished_at stamp")
        let b = try XCTUnwrap(store.scanRow(id: orphanB))
        XCTAssertEqual(b.state, "failed")
        let kept = try XCTUnwrap(store.scanRow(id: done))
        XCTAssertEqual(kept.state, "clean", "terminal scans are not touched")

        // One honest scan.finished event per orphan, carrying the exact reason.
        let finished = try store.listEvents(filter: EventFilter(kind: "scan.finished"))
        let reconciliations = finished.filter { $0.summary.contains("Interrupted by a restart") }
        XCTAssertEqual(reconciliations.count, 2, "one event per orphan; got \(finished.map(\.summary))")
        XCTAssertTrue(reconciliations.allSatisfy { $0.summary.contains("did not finish") })
    }

    func testFailOrphanedRunningScansIsIdempotent() throws {
        let store = try makeStore()
        _ = try store.createScan(
            deviceID: nil, volumePath: "/Volumes/STICK", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning STICK", at: base)
        XCTAssertEqual(try store.failOrphanedRunningScans(reason: "Interrupted by a restart", at: base), 1)
        XCTAssertEqual(try store.failOrphanedRunningScans(reason: "Interrupted by a restart", at: base), 0,
                       "a second reconcile finds nothing to do")
    }

    // MARK: - 2. Retention prune covers scan rows

    func testPruneRetentionDeletesOldScansAndTheirFindings() throws {
        let store = try makeStore()
        let old = base.addingTimeInterval(-40 * 86_400)
        let oldScan = try store.createScan(
            deviceID: nil, volumePath: "/Volumes/OLD", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning OLD", at: old)
        try store.updateScan(id: oldScan, state: "infected", filesScanned: 5,
                             finishedSummary: "Scan finished: 1 infected file(s) found.",
                             deviceID: nil, at: old.addingTimeInterval(10))
        try store.insertScanFinding(scanID: oldScan, filePath: "/Volumes/OLD/evil.exe",
                                    signature: "Eicar-Test-Signature", action: "reported_only",
                                    quarantinePath: nil)
        let fresh = try store.createScan(
            deviceID: nil, volumePath: "/Volumes/FRESH", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning FRESH", at: base.addingTimeInterval(-3_600))
        try store.updateScan(id: fresh, state: "clean", filesScanned: 2,
                             finishedSummary: "Scan finished: clean.", deviceID: nil,
                             at: base.addingTimeInterval(-3_590))

        _ = try store.pruneRetention(olderThanDays: 30, at: base)

        XCTAssertNil(try store.scanRow(id: oldScan), "scans older than retention are pruned")
        XCTAssertTrue(try store.scanFindingRows(scanID: oldScan).isEmpty,
                      "pruned scans take their findings with them (FK hygiene)")
        XCTAssertNotNil(try store.scanRow(id: fresh), "scans inside the window survive")
    }

    func testPruneRetentionStillWritesTheMarkerForEvents() throws {
        let store = try makeStore()
        let old = base.addingTimeInterval(-40 * 86_400)
        try store.appendEvent(kind: "device.attached", severity: "info",
                              summary: "Old event.", at: old)
        let deleted = try store.pruneRetention(olderThanDays: 30, at: base)
        XCTAssertEqual(deleted, 1)
        let markers = try store.listEvents(filter: EventFilter(kind: "monitoring.gap"))
        XCTAssertEqual(markers.count, 1, "pruning still writes ONE marker event")
    }

    // MARK: - 3. One-time internal-system-volume cleanup

    func testCleanupDeletesFailedScansOnInternalSystemVolumesOnly() throws {
        let store = try makeStore()
        func failedScan(_ path: String) throws -> String {
            let id = try store.createScan(
                deviceID: nil, volumePath: path, engine: "clamscan",
                defsAgeDays: nil, startedBy: "system",
                startedSummary: "Scanning \(path)", at: base)
            try store.updateScan(id: id, state: "failed", filesScanned: 0,
                                 finishedSummary: "Scan of \(path) failed (engine error).",
                                 deviceID: nil, at: base.addingTimeInterval(1))
            return id
        }
        let preboot = try failedScan("/System/Volumes/Preboot")
        let xarts = try failedScan("/System/Volumes/xarts")
        let root = try failedScan("/")
        let userStick = try failedScan("/Volumes/STICK")
        // A CLEAN scan on an internal path (should not exist, but must survive:
        // the cleanup targets only the historical `failed` junk).
        let cleanInternal = try store.createScan(
            deviceID: nil, volumePath: "/System/Volumes/VM", engine: "clamscan",
            defsAgeDays: nil, startedBy: "system",
            startedSummary: "Scanning VM", at: base)
        try store.updateScan(id: cleanInternal, state: "clean", filesScanned: 1,
                             finishedSummary: "Scan finished: clean.", deviceID: nil,
                             at: base.addingTimeInterval(1))

        let deleted = try store.deleteInternalSystemVolumeFailedScans()
        XCTAssertEqual(deleted, 3)

        XCTAssertNil(try store.scanRow(id: preboot))
        XCTAssertNil(try store.scanRow(id: xarts))
        XCTAssertNil(try store.scanRow(id: root))
        XCTAssertNotNil(try store.scanRow(id: userStick),
                        "a user volume that happened to fail is kept")
        XCTAssertNotNil(try store.scanRow(id: cleanInternal),
                        "only failed rows are cleaned up")
        // Idempotent: nothing left to delete.
        XCTAssertEqual(try store.deleteInternalSystemVolumeFailedScans(), 0)
    }
}
