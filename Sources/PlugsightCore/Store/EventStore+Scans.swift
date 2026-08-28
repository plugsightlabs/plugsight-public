// EventStore+Scans.swift  (N7, unified by N8)
//
// Scan-lifecycle writes to the FROZEN v1 schema (docs/spec/06): create a scan
// row, update its terminal state, insert findings, raise a scan_finding alert,
// and append the timeline events (`scan.started`, `scan.finished`,
// `scan.skipped`, and `alert.raised` for a finding). Reads used to verify and to
// render `scan.get` are provided too. Everything is SQLite writes with BOUND
// arguments (02's no-interpolation rule).
//
// N8 UNIFICATION: this extension originally opened its own path-keyed GRDB
// connection (and used a separate ULID generator) because N2's writer was
// `private` and the parallel-node collision rule forbade editing
// EventStore.swift. N8 owns integration, so the extension now shares the ONE
// `dbQueue` and the ONE `ulid` generator of its EventStore instance — one
// writer connection, one id sequence, id order == time order across all
// writers. Each method still commits its rows in ONE transaction.

import Foundation
import GRDB

extension EventStore {

    // MARK: - Id generation (the store's shared generator)

    private func nextID(_ prefix: String, _ now: Date) -> String {
        prefix + ulid.next(now: now)
    }

    /// Insert one events row inside an existing transaction (bound arguments).
    private func insertEvent(
        _ db: Database, id: String, at: Date, kind: String, severity: String,
        deviceID: String?, actor: String, summary: String, detail: String, alertID: String?
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO events (id, at, kind, severity, device_id, actor, summary, detail, alert_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, ISO8601Millis.string(at), kind, severity, deviceID, actor, summary, detail, alertID]
        )
    }

    // MARK: - Writes

    /// Create a `running` scan row and append the `scan.started` event, atomically.
    @discardableResult
    public func createScan(
        deviceID: String?,
        volumePath: String,
        engine: String,
        defsAgeDays: Int?,
        startedBy: String,
        startedSummary: String,
        detail: String = "{}",
        actor: String = "system",
        at: Date = Date()
    ) throws -> String {
        let scanID = nextID("scn_", at)
        let eventID = nextID("evt_", at)
        let ts = ISO8601Millis.string(at)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO scans
                  (id, device_id, volume_path, engine, defs_age_days, state,
                   started_at, finished_at, files_scanned, started_by)
                VALUES (?, ?, ?, ?, ?, 'running', ?, NULL, 0, ?)
                """,
                arguments: [scanID, deviceID, volumePath, engine, defsAgeDays, ts, startedBy]
            )
            try insertEvent(
                db, id: eventID, at: at, kind: "scan.started", severity: "info",
                deviceID: deviceID, actor: actor, summary: startedSummary, detail: detail, alertID: nil
            )
        }
        notifyObservers(StoredEvent(
            id: eventID, at: ts, kind: "scan.started", severity: "info",
            deviceID: deviceID, actor: actor, summary: startedSummary, detail: detail, alertID: nil
        ))
        return scanID
    }

    /// Move a scan to a terminal state (`clean`/`infected`/`failed`/`canceled`),
    /// stamp `finished_at` and `files_scanned`, and append `scan.finished`.
    public func updateScan(
        id: String,
        state: String,
        filesScanned: Int,
        finishedSummary: String,
        deviceID: String?,
        detail: String = "{}",
        actor: String = "system",
        at: Date = Date()
    ) throws {
        let ts = ISO8601Millis.string(at)
        let eventID = nextID("evt_", at)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE scans SET state = ?, finished_at = ?, files_scanned = ? WHERE id = ?",
                arguments: [state, ts, filesScanned, id]
            )
            try insertEvent(
                db, id: eventID, at: at, kind: "scan.finished", severity: "info",
                deviceID: deviceID, actor: actor, summary: finishedSummary, detail: detail, alertID: nil
            )
        }
        notifyObservers(StoredEvent(
            id: eventID, at: ts, kind: "scan.finished", severity: "info",
            deviceID: deviceID, actor: actor, summary: finishedSummary, detail: detail, alertID: nil
        ))
    }

    /// Insert one `scan_findings` row (no event; the alert is raised separately).
    public func insertScanFinding(
        scanID: String,
        filePath: String,
        signature: String,
        action: String,
        quarantinePath: String?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO scan_findings (scan_id, file_path, signature, action, quarantine_path)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [scanID, filePath, signature, action, quarantinePath]
            )
        }
    }

    /// Raise a `scan_finding` alert (state `active`) and append the matching
    /// `alert.raised` event carrying the new alert id. Returns the alert id.
    @discardableResult
    public func raiseScanAlert(
        deviceID: String?,
        severity: String,
        summary: String,
        why: String,
        detail: String = "{}",
        actor: String = "system",
        at: Date = Date()
    ) throws -> String {
        let alertID = nextID("alr_", at)
        let eventID = nextID("evt_", at)
        let ts = ISO8601Millis.string(at)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO alerts
                  (id, device_id, rule, severity, state, raised_at, updated_at, summary, why)
                VALUES (?, ?, 'scan_finding', ?, 'active', ?, ?, ?, ?)
                """,
                arguments: [alertID, deviceID, severity, ts, ts, summary, why]
            )
            try insertEvent(
                db, id: eventID, at: at, kind: "alert.raised", severity: severity,
                deviceID: deviceID, actor: actor, summary: summary, detail: detail, alertID: alertID
            )
        }
        notifyObservers(StoredEvent(
            id: eventID, at: ts, kind: "alert.raised", severity: severity,
            deviceID: deviceID, actor: actor, summary: summary, detail: detail, alertID: alertID
        ))
        return alertID
    }

    /// Record a `skipped` scan (already finished) and append `scan.skipped`. Used
    /// when a scan is declined (engine unavailable, trusted device, policy off).
    @discardableResult
    public func recordSkippedScan(
        deviceID: String?,
        volumePath: String,
        engine: String,
        startedBy: String,
        skippedSummary: String,
        detail: String = "{}",
        actor: String = "system",
        at: Date = Date()
    ) throws -> String {
        let scanID = nextID("scn_", at)
        let eventID = nextID("evt_", at)
        let ts = ISO8601Millis.string(at)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO scans
                  (id, device_id, volume_path, engine, defs_age_days, state,
                   started_at, finished_at, files_scanned, started_by)
                VALUES (?, ?, ?, ?, NULL, 'skipped', ?, ?, 0, ?)
                """,
                arguments: [scanID, deviceID, volumePath, engine, ts, ts, startedBy]
            )
            try insertEvent(
                db, id: eventID, at: at, kind: "scan.skipped", severity: "info",
                deviceID: deviceID, actor: actor, summary: skippedSummary, detail: detail, alertID: nil
            )
        }
        notifyObservers(StoredEvent(
            id: eventID, at: ts, kind: "scan.skipped", severity: "info",
            deviceID: deviceID, actor: actor, summary: skippedSummary, detail: detail, alertID: nil
        ))
        return scanID
    }

    // MARK: - Reads (verification + scan.get rendering)

    public func scanRow(id: String) throws -> ScanRowSnapshot? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM scans WHERE id = ?", arguments: [id]
            ) else { return nil }
            return ScanRowSnapshot(
                id: row["id"], deviceID: row["device_id"], volumePath: row["volume_path"],
                engine: row["engine"], defsAgeDays: row["defs_age_days"], state: row["state"],
                startedAt: row["started_at"], finishedAt: row["finished_at"],
                filesScanned: row["files_scanned"], startedBy: row["started_by"]
            )
        }
    }

    public func scanFindingRows(scanID: String) throws -> [ScanFindingSnapshot] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM scan_findings WHERE scan_id = ? ORDER BY file_path",
                arguments: [scanID]
            ).map {
                ScanFindingSnapshot(
                    scanID: $0["scan_id"], filePath: $0["file_path"], signature: $0["signature"],
                    action: $0["action"], quarantinePath: $0["quarantine_path"]
                )
            }
        }
    }

    public func scanAlertRows() throws -> [ScanAlertSnapshot] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM alerts WHERE rule = 'scan_finding' ORDER BY id DESC"
            ).map {
                ScanAlertSnapshot(
                    id: $0["id"], deviceID: $0["device_id"], rule: $0["rule"],
                    severity: $0["severity"], state: $0["state"],
                    summary: $0["summary"], why: $0["why"]
                )
            }
        }
    }
}

// MARK: - Plain snapshots (platform-neutral, no GRDB across the boundary)

public struct ScanRowSnapshot: Equatable, Sendable {
    public let id: String
    public let deviceID: String?
    public let volumePath: String
    public let engine: String
    public let defsAgeDays: Int?
    public let state: String
    public let startedAt: String
    public let finishedAt: String?
    public let filesScanned: Int
    public let startedBy: String
}

public struct ScanFindingSnapshot: Equatable, Sendable {
    public let scanID: String
    public let filePath: String
    public let signature: String
    public let action: String
    public let quarantinePath: String?
}

public struct ScanAlertSnapshot: Equatable, Sendable {
    public let id: String
    public let deviceID: String?
    public let rule: String
    public let severity: String
    public let state: String
    public let summary: String
    public let why: String
}
