// EventStore+Quarantine.swift  (NQR — owner ruling D6; unified by N8)
//
// Store surface for un-quarantining (`quarantine.restore`). Adds NO migration
// and does NOT change the frozen v1 schema — in particular
// `scan_findings.action` keeps its CHECK IN ('quarantined','reported_only'); a
// restore is recorded as a NEW EVENT (`quarantine.restored`) plus the
// filesystem move, never a row/action mutation.
//
// N8 UNIFICATION: originally opened a short-lived path-keyed GRDB connection
// (and used a separate ULID generator) because N2's writer was `private` under
// the parallel-node collision rule. It now shares the ONE `dbQueue` and the ONE
// `ulid` generator of its EventStore instance. Every statement uses bound `?`
// arguments — no SQL value interpolation.

import Foundation
import GRDB

/// The quarantine record a restore addresses: the finding it belongs to, plus the
/// owning scan's device so the restore event can be device-scoped.
public struct QuarantineFindingSnapshot: Equatable, Sendable {
    public let scanID: String
    public let deviceID: String?
    public let filePath: String
    public let signature: String
    public let quarantinePath: String
}

extension EventStore {

    // MARK: - Read: locate a quarantine record by its sha-256 id

    /// Find the quarantined finding whose `quarantine_path` is named by
    /// `quarantineId` (the sha-256 leaf the contain mover assigned). Joins the
    /// owning scan for its device. Returns nil when no such finding exists — the
    /// API layer turns that into `not_found`, and distinguishes it from an
    /// already-restored slot (finding present, files gone -> `conflict`).
    public func quarantineFinding(quarantineId: String) throws -> QuarantineFindingSnapshot? {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT sf.scan_id AS scan_id, sf.file_path AS file_path,
                       sf.signature AS signature, sf.quarantine_path AS quarantine_path,
                       s.device_id AS device_id
                FROM scan_findings sf
                JOIN scans s ON s.id = sf.scan_id
                WHERE sf.action = 'quarantined' AND sf.quarantine_path IS NOT NULL
                """
            )
            for row in rows {
                let quarantinePath: String = row["quarantine_path"]
                if (quarantinePath as NSString).lastPathComponent == quarantineId {
                    return QuarantineFindingSnapshot(
                        scanID: row["scan_id"],
                        deviceID: row["device_id"],
                        filePath: row["file_path"],
                        signature: row["signature"],
                        quarantinePath: quarantinePath
                    )
                }
            }
            return nil
        }
    }

    // MARK: - Write: the quarantine.restored event

    /// Append a `quarantine.restored` event (severity `notice`) and return the full
    /// stored event so the caller can fan it out and quote it. This is the ONLY
    /// record of a restore besides the filesystem move — the schema is untouched.
    @discardableResult
    public func appendQuarantineRestoredEvent(
        deviceID: String?,
        actor: String,
        summary: String,
        detail: String = "{}",
        at now: Date = Date()
    ) throws -> StoredEvent {
        try appendStoredEvent(kind: "quarantine.restored", severity: "notice",
                              deviceID: deviceID, actor: actor, summary: summary,
                              detail: detail, at: now)
    }

    // MARK: - Read: verification (tests + audit)

    /// All `quarantine.restored` events, newest first.
    public func quarantineRestoredEvents() throws -> [StoredEvent] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, at, kind, severity, device_id, actor, summary, detail, alert_id
                FROM events WHERE kind = 'quarantine.restored' ORDER BY id DESC
                """
            ).map {
                StoredEvent(
                    id: $0["id"], at: $0["at"], kind: $0["kind"], severity: $0["severity"],
                    deviceID: $0["device_id"], actor: $0["actor"], summary: $0["summary"],
                    detail: $0["detail"], alertID: $0["alert_id"]
                )
            }
        }
    }
}
