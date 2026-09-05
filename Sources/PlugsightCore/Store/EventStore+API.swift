// EventStore+API.swift
//
// N4-owned store surface for the local API (unified by N8). Adds NO migration
// (06's schema is frozen and complete). `APIStore` carries every read/mutation
// the API needs plus the seed helpers the tests use to create
// alerts/scans/scores/policy rows. Every statement uses bound `?` arguments —
// no SQL value interpolation (02 security rule).
//
// N8 UNIFICATION: `APIStore` originally opened its own GRDB connection by path
// (N2's writer was `private` under the parallel-node collision rule). It is now
// a facade over ONE `EventStore`: it shares that store's `dbQueue` and `ulid`
// generator, so the daemon's analyzer, the scan orchestrator, and the API layer
// all write through one connection and one id sequence. The `init(path:)`
// convenience remains for callers/tests that start from a bare path.

import Foundation
import GRDB

// MARK: - Value types

public struct StoredGap: Equatable, Sendable {
    public let from: String
    public let to: String
}

public struct StatusCounts: Equatable, Sendable {
    public let devicesPresent: Int
    public let activeAlerts: Int
    public let eventCount: Int
    public let gaps: [StoredGap]
}

public struct StoredAlert: Equatable, Sendable {
    public let id: String
    public let deviceID: String?
    public let rule: String
    public let severity: String
    public let state: String
    public let raisedAt: String
    public let updatedAt: String
    public let summary: String
    public let why: String
    public let ackedBy: String?
    public let ackedAt: String?
    public let ackComment: String?
}

public struct StoredScore: Equatable, Sendable {
    public let deviceID: String
    public let at: String
    public let score: Int
    public let confidence: String
    /// JSON array of signal objects (03's score shape), stored verbatim.
    public let signals: String
}

public struct StoredFinding: Equatable, Sendable {
    public let scanID: String
    public let filePath: String
    public let signature: String
    public let action: String
    public let quarantinePath: String?
}

/// The most recent scan for a device, briefly: enough for a device summary to
/// say what happened last without loading findings.
public struct StoredScanBrief: Equatable, Sendable {
    public let id: String
    public let state: String
    public let finishedAt: String?
}

public struct StoredScan: Equatable, Sendable {
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
    public let findings: [StoredFinding]

    /// Terminal states never transition further (used for scan.cancel conflict).
    public var isTerminal: Bool {
        state == "clean" || state == "infected" || state == "failed"
            || state == "canceled" || state == "skipped"
    }
}

// MARK: - APIStore

/// The N4 read/write surface over the Plugsight database, for the local API.
/// A facade over ONE `EventStore` (N8 unification): same connection, same ULID
/// generator.
public final class APIStore {
    /// The single underlying store this facade shares its writer with.
    public let eventStore: EventStore
    private var dbQueue: DatabaseQueue { eventStore.dbQueue }
    private var ulid: ULIDGenerator { eventStore.ulid }

    public static let maxPageLimit = 500

    /// Share the given store's connection and id generator (the daemon topology:
    /// ONE writer for analyzer, scans, and API).
    public init(store: EventStore) {
        self.eventStore = store
    }

    /// Open the database at `path` (migrations run via EventStore's init).
    /// Convenience for callers/tests that start from a bare path.
    public convenience init(path: String, ulid: ULIDGenerator = ULIDGenerator()) throws {
        self.init(store: try EventStore(path: path, ulid: ulid))
    }

    private static func clampLimit(_ limit: Int) -> Int { min(max(limit, 1), maxPageLimit) }

    // MARK: - Append (API-generated timeline events)

    /// Append a history row and return the full stored event, so a mutation can
    /// fan it out over the broadcaster and return it to the caller.
    @discardableResult
    public func appendEvent(
        kind: String,
        severity: String,
        deviceID: String? = nil,
        actor: String = "system",
        summary: String,
        detail: String = "{}",
        alertID: String? = nil,
        at now: Date = Date()
    ) throws -> StoredEvent {
        try eventStore.appendStoredEvent(kind: kind, severity: severity,
                                         deviceID: deviceID, actor: actor,
                                         summary: summary, detail: detail,
                                         alertID: alertID, at: now)
    }

    // MARK: - status.get

    public func statusCounts(gapLimit: Int = 20) throws -> StatusCounts {
        try dbQueue.read { db in
            let present = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM devices WHERE present = 1") ?? 0
            let active = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM alerts WHERE state = 'active'") ?? 0
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0
            let gapRows = try Row.fetchAll(
                db,
                sql: "SELECT detail FROM events WHERE kind = 'monitoring.gap' ORDER BY id DESC LIMIT ?",
                arguments: [gapLimit]
            )
            let gaps: [StoredGap] = gapRows.compactMap { row in
                let detail: String = row["detail"] ?? "{}"
                guard let data = detail.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                let from = (obj["from"] as? String) ?? (obj["pruned_from"] as? String)
                let to = (obj["to"] as? String) ?? (obj["pruned_to"] as? String)
                guard let from, let to else { return nil }
                return StoredGap(from: from, to: to)
            }
            return StatusCounts(devicesPresent: present, activeAlerts: active, eventCount: events, gaps: gaps)
        }
    }

    // MARK: - devices

    /// Device summaries with cursor pagination. `deviceClass` filters to devices
    /// having an interface whose role matches. Newest device id first.
    public func listDevices(present: Bool? = nil, trust: String? = nil, deviceClass: String? = nil,
                            limit: Int = maxPageLimit, cursor: String? = nil) throws -> [StoredDevice] {
        let lim = Self.clampLimit(limit)
        var conds: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if let present, present { conds.append("present = 1") }
        if let present, !present { conds.append("present = 0") }
        if let trust { conds.append("trust_tier = ?"); args.append(trust) }
        if let deviceClass {
            conds.append("id IN (SELECT device_id FROM device_interfaces WHERE role = ?)")
            args.append(deviceClass)
        }
        if let cursor { conds.append("id < ?"); args.append(cursor) }
        let whereClause = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        args.append(lim)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db,
                sql: "SELECT * FROM devices \(whereClause) ORDER BY id DESC LIMIT ?",
                arguments: StatementArguments(args))
            return try rows.map { try Self.device(from: $0, db: db) }
        }
    }

    /// identity_key -> trust_tier for EVERY known device: the trust table the
    /// ES policy snapshot carries (05). One row per physical device ever seen,
    /// so no paging; the map is small by nature.
    public func trustTiersByIdentityKey() throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT identity_key, trust_tier FROM devices")
            var out: [String: String] = [:]
            for r in rows { out[r["identity_key"] as String] = r["trust_tier"] as String }
            return out
        }
    }

    /// The device row id for an identity key, so ES hold events (volume.held /
    /// volume.released) can name the device they concern.
    public func deviceID(forIdentityKey key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM devices WHERE identity_key = ?", arguments: [key])
        }
    }

    public func getDevice(id: String) throws -> StoredDevice? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM devices WHERE id = ?", arguments: [id]) else { return nil }
            return try Self.device(from: row, db: db)
        }
    }

    public func interfaceRoles(deviceID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db,
                sql: "SELECT role FROM device_interfaces WHERE device_id = ? ORDER BY seq",
                arguments: [deviceID])
        }
    }

    public func latestScore(deviceID: String) throws -> StoredScore? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT device_id, at, score, confidence, signals FROM score_snapshots WHERE device_id = ? ORDER BY id DESC LIMIT 1",
                arguments: [deviceID]) else { return nil }
            return StoredScore(deviceID: row["device_id"], at: row["at"], score: row["score"],
                               confidence: row["confidence"], signals: row["signals"])
        }
    }

    public func activeAlertCount(deviceID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM alerts WHERE device_id = ? AND state = 'active'", arguments: [deviceID]) ?? 0
        }
    }

    /// Active (unacknowledged) alert counts by severity, for the safety verdict:
    /// critical drives red, warning drives yellow (04 verdict model).
    public func activeAlertSeverityCounts(deviceID: String) throws -> (critical: Int, warning: Int) {
        try dbQueue.read { db in
            var critical = 0, warning = 0
            let rows = try Row.fetchAll(db,
                sql: "SELECT severity, COUNT(*) AS n FROM alerts WHERE device_id = ? AND state = 'active' GROUP BY severity",
                arguments: [deviceID])
            for row in rows {
                let severity: String = row["severity"]
                let n: Int = row["n"]
                if severity == "critical" { critical = n }
                if severity == "warning" { warning = n }
            }
            return (critical, warning)
        }
    }

    public func eventCount(deviceID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE device_id = ?", arguments: [deviceID]) ?? 0
        }
    }

    public func scanCount(deviceID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scans WHERE device_id = ?", arguments: [deviceID]) ?? 0
        }
    }

    /// True when the device has a scan still in the `running` state (drives the
    /// device summary's `scanning` flag).
    public func hasRunningScan(deviceID: String) throws -> Bool {
        try dbQueue.read { db in
            (try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM scans WHERE device_id = ? AND state = 'running'",
                arguments: [deviceID]) ?? 0) > 0
        }
    }

    /// The device's most recent scan, as the brief the device summary carries
    /// (no findings loaded). Newest by id (ULIDs are time-ordered).
    public func latestScanBrief(deviceID: String) throws -> StoredScanBrief? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT id, state, finished_at FROM scans WHERE device_id = ? ORDER BY id DESC LIMIT 1",
                arguments: [deviceID]) else { return nil }
            return StoredScanBrief(id: row["id"], state: row["state"], finishedAt: row["finished_at"])
        }
    }

    /// The device's most recent TERMINAL scan (running excluded), for the safety
    /// verdict: a rescan in flight must not erase the standing verdict, and a
    /// first scan still running is "not checked yet", not a result.
    public func latestTerminalScanBrief(deviceID: String) throws -> StoredScanBrief? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT id, state, finished_at FROM scans WHERE device_id = ? AND state != 'running' ORDER BY id DESC LIMIT 1",
                arguments: [deviceID]) else { return nil }
            return StoredScanBrief(id: row["id"], state: row["state"], finishedAt: row["finished_at"])
        }
    }

    // MARK: - timeline / events

    /// Newest-first timeline query with 02's full filter set.
    public func timeline(deviceID: String? = nil, kinds: [String]? = nil, severity: String? = nil,
                         since: String? = nil, until: String? = nil,
                         limit: Int = maxPageLimit, cursor: String? = nil) throws -> [StoredEvent] {
        let lim = Self.clampLimit(limit)
        var conds: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if let deviceID { conds.append("device_id = ?"); args.append(deviceID) }
        if let kinds, !kinds.isEmpty {
            let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
            conds.append("kind IN (\(placeholders))")
            args.append(contentsOf: kinds)
        }
        if let severity { conds.append("severity = ?"); args.append(severity) }
        if let since { conds.append("at >= ?"); args.append(since) }
        if let until { conds.append("at <= ?"); args.append(until) }
        if let cursor { conds.append("id < ?"); args.append(cursor) }
        let whereClause = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        args.append(lim)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db,
                sql: "SELECT id, at, kind, severity, device_id, actor, summary, detail, alert_id FROM events \(whereClause) ORDER BY id DESC LIMIT ?",
                arguments: StatementArguments(args))
            return rows.map(Self.event(from:))
        }
    }

    public func getEvent(id: String) throws -> StoredEvent? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT id, at, kind, severity, device_id, actor, summary, detail, alert_id FROM events WHERE id = ?",
                arguments: [id]) else { return nil }
            return Self.event(from: row)
        }
    }

    /// The `why` reasoning of the alert an event belongs to, if any.
    public func alertWhy(alertID: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT why FROM alerts WHERE id = ?", arguments: [alertID])
        }
    }

    // MARK: - alerts

    public func listAlerts(state: String? = nil, severity: String? = nil, deviceID: String? = nil,
                           limit: Int = maxPageLimit, cursor: String? = nil) throws -> [StoredAlert] {
        let lim = Self.clampLimit(limit)
        var conds: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if let state { conds.append("state = ?"); args.append(state) }
        if let severity { conds.append("severity = ?"); args.append(severity) }
        if let deviceID { conds.append("device_id = ?"); args.append(deviceID) }
        if let cursor { conds.append("id < ?"); args.append(cursor) }
        let whereClause = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        args.append(lim)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM alerts \(whereClause) ORDER BY id DESC LIMIT ?",
                                        arguments: StatementArguments(args))
            return rows.map(Self.alert(from:))
        }
    }

    public func getAlert(id: String) throws -> StoredAlert? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM alerts WHERE id = ?", arguments: [id]) else { return nil }
            return Self.alert(from: row)
        }
    }

    /// Move an alert to acknowledged. Caller checks the current state first for
    /// the conflict rule. Returns the updated alert.
    public func acknowledgeAlert(id: String, comment: String?, actor: String, at now: Date = Date()) throws -> StoredAlert {
        let at = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE alerts SET state = 'acknowledged', acked_by = ?, acked_at = ?, ack_comment = ?, updated_at = ? WHERE id = ?",
                arguments: [actor, at, comment, at, id])
        }
        guard let a = try getAlert(id: id) else {
            throw DatabaseError(message: "alert vanished after ack")
        }
        return a
    }

    // MARK: - trust

    /// Update a device's trust tier. Caller emits the trust.changed event so the
    /// old tier can be captured first. Returns the updated device.
    public func setTrust(deviceID: String, tier: String, note: String?, actor: String, at now: Date = Date()) throws -> StoredDevice {
        let at = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE devices SET trust_tier = ?, trust_note = ?, trust_set_by = ?, trust_set_at = ? WHERE id = ?",
                arguments: [tier, note, actor, at, deviceID])
        }
        guard let d = try getDevice(id: deviceID) else {
            throw DatabaseError(message: "device vanished after trust.set")
        }
        return d
    }

    // MARK: - policy

    /// Full policy, defaults overlaid with stored per-key rows.
    public func policyRaw() throws -> [String: Data] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM policy")
            var out: [String: Data] = [:]
            for r in rows {
                let key: String = r["key"]
                let value: String = r["value"]
                out[key] = Data(value.utf8)
            }
            return out
        }
    }

    public func setPolicyKey(_ key: String, valueJSON: String, actor: String, at now: Date = Date()) throws {
        let at = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO policy (key, value, updated_at, updated_by) VALUES (?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by
                """,
                arguments: [key, valueJSON, at, actor])
        }
    }

    // MARK: - scans

    public func insertScan(deviceID: String?, volumePath: String, engine: String, startedBy: String, at now: Date = Date()) throws -> StoredScan {
        let id = "scn_" + ulid.next(now: now)
        let at = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO scans (id, device_id, volume_path, engine, defs_age_days, state, started_at, finished_at, files_scanned, started_by)
                VALUES (?, ?, ?, ?, NULL, 'running', ?, NULL, 0, ?)
                """,
                arguments: [id, deviceID, volumePath, engine, at, startedBy])
        }
        return try getScan(id: id)!
    }

    public func getScan(id: String) throws -> StoredScan? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM scans WHERE id = ?", arguments: [id]) else { return nil }
            let findings = try Self.findings(scanID: id, db: db)
            return Self.scan(from: row, findings: findings)
        }
    }

    public func listScans(deviceID: String? = nil, limit: Int = maxPageLimit, cursor: String? = nil) throws -> [StoredScan] {
        let lim = Self.clampLimit(limit)
        var conds: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if let deviceID { conds.append("device_id = ?"); args.append(deviceID) }
        if let cursor { conds.append("id < ?"); args.append(cursor) }
        let whereClause = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        args.append(lim)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM scans \(whereClause) ORDER BY id DESC LIMIT ?",
                                        arguments: StatementArguments(args))
            return try rows.map { row in
                let id: String = row["id"]
                let findings = try Self.findings(scanID: id, db: db)
                return Self.scan(from: row, findings: findings)
            }
        }
    }

    /// Mark a scan canceled. Caller checks terminal state first for the conflict
    /// rule. Returns the updated scan.
    public func cancelScan(id: String, at now: Date = Date()) throws -> StoredScan {
        let at = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE scans SET state = 'canceled', finished_at = ? WHERE id = ?", arguments: [at, id])
        }
        return try getScan(id: id)!
    }

    // MARK: - Seed helpers (no public N2 writer exists for these tables)

    public func seedAlert(id: String, deviceID: String?, rule: String, severity: String, state: String,
                          summary: String, why: String, at now: Date = Date()) throws {
        let at = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO alerts (id, device_id, rule, severity, state, raised_at, updated_at, summary, why, acked_by, acked_at, ack_comment)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL)
                """,
                arguments: [id, deviceID, rule, severity, state, at, at, summary, why])
        }
    }

    public func seedScore(deviceID: String, score: Int, confidence: String, signals: String, at now: Date = Date()) throws {
        let id = "scr_" + ulid.next(now: now)
        let at = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO score_snapshots (id, device_id, at, score, confidence, signals) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [id, deviceID, at, score, confidence, signals])
        }
    }

    public func seedFinding(scanID: String, filePath: String, signature: String, action: String, quarantinePath: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO scan_findings (scan_id, file_path, signature, action, quarantine_path) VALUES (?, ?, ?, ?, ?)",
                arguments: [scanID, filePath, signature, action, quarantinePath])
        }
    }

    public func setScanState(id: String, state: String, filesScanned: Int? = nil, finishedAt: Date? = nil) throws {
        try dbQueue.write { db in
            if let filesScanned {
                try db.execute(sql: "UPDATE scans SET state = ?, files_scanned = ? WHERE id = ?", arguments: [state, filesScanned, id])
            } else {
                try db.execute(sql: "UPDATE scans SET state = ? WHERE id = ?", arguments: [state, id])
            }
            if let finishedAt {
                try db.execute(sql: "UPDATE scans SET finished_at = ? WHERE id = ?", arguments: [ISO8601Millis.string(finishedAt), id])
            }
        }
    }

    // MARK: - Row mapping

    private static func event(from row: Row) -> StoredEvent {
        StoredEvent(id: row["id"], at: row["at"], kind: row["kind"], severity: row["severity"],
                    deviceID: row["device_id"], actor: row["actor"], summary: row["summary"],
                    detail: row["detail"], alertID: row["alert_id"])
    }

    private static func alert(from row: Row) -> StoredAlert {
        StoredAlert(id: row["id"], deviceID: row["device_id"], rule: row["rule"], severity: row["severity"],
                    state: row["state"], raisedAt: row["raised_at"], updatedAt: row["updated_at"],
                    summary: row["summary"], why: row["why"], ackedBy: row["acked_by"],
                    ackedAt: row["acked_at"], ackComment: row["ack_comment"])
    }

    private static func scan(from row: Row, findings: [StoredFinding]) -> StoredScan {
        StoredScan(id: row["id"], deviceID: row["device_id"], volumePath: row["volume_path"],
                   engine: row["engine"], defsAgeDays: row["defs_age_days"], state: row["state"],
                   startedAt: row["started_at"], finishedAt: row["finished_at"],
                   filesScanned: row["files_scanned"], startedBy: row["started_by"], findings: findings)
    }

    private static func findings(scanID: String, db: Database) throws -> [StoredFinding] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM scan_findings WHERE scan_id = ? ORDER BY file_path", arguments: [scanID])
        return rows.map {
            StoredFinding(scanID: scanID, filePath: $0["file_path"], signature: $0["signature"],
                          action: $0["action"], quarantinePath: $0["quarantine_path"])
        }
    }

    private static func device(from row: Row, db: Database) throws -> StoredDevice {
        let id: String = row["id"]
        let interfaceRows = try Row.fetchAll(db,
            sql: "SELECT seq, usb_class, usb_subclass, usb_protocol, role FROM device_interfaces WHERE device_id = ? ORDER BY seq",
            arguments: [id])
        let interfaces = interfaceRows.map {
            StoredInterface(seq: $0["seq"], usbClass: $0["usb_class"], usbSubclass: $0["usb_subclass"],
                            usbProtocol: $0["usb_protocol"], role: $0["role"])
        }
        let present: Int = row["present"]
        return StoredDevice(id: id, identityKey: row["identity_key"], identityBasis: row["identity_basis"],
                            vid: row["vid"], pid: row["pid"], serial: row["serial"], vendorName: row["vendor_name"],
                            productName: row["product_name"], displayName: row["display_name"],
                            firstSeenAt: row["first_seen_at"], lastSeenAt: row["last_seen_at"],
                            present: present != 0, trustTier: row["trust_tier"], trustNote: row["trust_note"],
                            trustSetBy: row["trust_set_by"], trustSetAt: row["trust_set_at"], interfaces: interfaces)
    }
}
