// EventStore+Daemon.swift  (N8)
//
// Store writers the wired daemon's analyzer loop needs beyond N2's frozen core
// surface: raise/escalate detection alerts (mismatch rules, behavioral score),
// mark a device detached, and persist scorer snapshots. Same rules as every
// other store file: bound `?` arguments only, no schema changes, all writes on
// the ONE shared `dbQueue`, ids from the ONE shared `ulid` generator, and every
// event append notifies the observers (the in-process `event.appended` bus).

import Foundation
import GRDB

/// The active alert of a device, as the analyzer needs it for escalation.
public struct ActiveAlertSnapshot: Equatable, Sendable {
    public let id: String
    public let rule: String
    public let severity: String
}

extension EventStore {

    // MARK: - Alerts (analyzer-raised)

    /// Insert an `active` alert and append the matching `alert.raised` event,
    /// atomically. `rule` is 06's vocabulary ('R1'..'R6', 'behavioral_score',
    /// 'scan_finding'). Returns the alert id and the appended event.
    @discardableResult
    public func raiseAlert(
        rule: String,
        severity: String,
        deviceID: String?,
        summary: String,
        why: String,
        detail: String = "{}",
        actor: String = "system",
        at now: Date = Date()
    ) throws -> (alertID: String, event: StoredEvent) {
        let alertID = "alr_" + ulid.next(now: now)
        let eventID = "evt_" + ulid.next(now: now)
        let ts = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO alerts
                  (id, device_id, rule, severity, state, raised_at, updated_at, summary, why)
                VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?)
                """,
                arguments: [alertID, deviceID, rule, severity, ts, ts, summary, why]
            )
            try db.execute(
                sql: """
                INSERT INTO events (id, at, kind, severity, device_id, actor, summary, detail, alert_id)
                VALUES (?, ?, 'alert.raised', ?, ?, ?, ?, ?, ?)
                """,
                arguments: [eventID, ts, severity, deviceID, actor, summary, detail, alertID]
            )
        }
        let event = StoredEvent(id: eventID, at: ts, kind: "alert.raised", severity: severity,
                                deviceID: deviceID, actor: actor, summary: summary,
                                detail: detail, alertID: alertID)
        notifyObservers(event)
        return (alertID, event)
    }

    /// Escalate an existing alert: raise its severity (never lower it), stamp
    /// `updated_at`, and append an `alert.raised` event carrying the SAME alert
    /// id — the T1 story's "score jumps and the alert escalates" (02).
    @discardableResult
    public func escalateAlert(
        id alertID: String,
        toSeverity severity: String,
        deviceID: String?,
        summary: String,
        detail: String = "{}",
        actor: String = "system",
        at now: Date = Date()
    ) throws -> StoredEvent {
        let eventID = "evt_" + ulid.next(now: now)
        let ts = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE alerts SET severity = ?, updated_at = ? WHERE id = ?",
                arguments: [severity, ts, alertID]
            )
            try db.execute(
                sql: """
                INSERT INTO events (id, at, kind, severity, device_id, actor, summary, detail, alert_id)
                VALUES (?, ?, 'alert.raised', ?, ?, ?, ?, ?, ?)
                """,
                arguments: [eventID, ts, severity, deviceID, actor, summary, detail, alertID]
            )
        }
        let event = StoredEvent(id: eventID, at: ts, kind: "alert.raised", severity: severity,
                                deviceID: deviceID, actor: actor, summary: summary,
                                detail: detail, alertID: alertID)
        notifyObservers(event)
        return event
    }

    /// The newest `active` alert for a device, if any (escalation target).
    public func activeAlert(deviceID: String) throws -> ActiveAlertSnapshot? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, rule, severity FROM alerts WHERE device_id = ? AND state = 'active' ORDER BY id DESC LIMIT 1",
                arguments: [deviceID]
            ) else { return nil }
            return ActiveAlertSnapshot(id: row["id"], rule: row["rule"], severity: row["severity"])
        }
    }

    // MARK: - Detach

    /// Mark a device absent (detach): present = 0, `last_seen_at` stamped.
    public func markDetached(deviceID: String, at now: Date = Date()) throws {
        let ts = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE devices SET present = 0, last_seen_at = ? WHERE id = ?",
                arguments: [ts, deviceID]
            )
        }
    }

    // MARK: - Score snapshots (scorer persistence, step C)

    /// Insert one `score_snapshots` row ('scr_' + ULID). `signals` is the JSON
    /// array of signal objects (03's score shape), stored verbatim.
    @discardableResult
    public func insertScoreSnapshot(
        deviceID: String,
        score: Int,
        confidence: String,
        signals: String,
        at now: Date = Date()
    ) throws -> String {
        let id = "scr_" + ulid.next(now: now)
        let ts = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO score_snapshots (id, device_id, at, score, confidence, signals) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [id, deviceID, ts, score, confidence, signals]
            )
        }
        return id
    }
}
