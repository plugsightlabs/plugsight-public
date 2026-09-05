// EventStore.swift
//
// The one writer to the Plugsight SQLite database (docs/spec/06). Everything
// here uses GRDB with WAL mode and prepared statements with bound arguments —
// the store NEVER interpolates values into SQL (02 security rule). Column and
// table names are the only literal text in a statement; every value crosses as
// a bound `?` argument.
//
// Write paths:
//   - appendEvent(...)   the ONLY write path for history rows
//   - upsertDevice(...)  create-or-touch a device by its stable identity
//   - pruneRetention(...) trim old events + score snapshots + scans, leave a marker
// Read paths:
//   - listEvents / listDevices  newest-first, ULID-cursor pagination
//   - getDevice

import Foundation
import GRDB

public final class EventStore {
    /// The ONE writer connection (N8 unification): extensions in this module
    /// (EventStore+API/+Scans/+Quarantine) share this queue instead of opening
    /// their own path-keyed connections.
    let dbQueue: DatabaseQueue
    /// The ONE ULID generator: every id minted against this store comes from
    /// here, so id order == time order across ALL writers.
    let ulid: ULIDGenerator

    /// Hard cap on any page size (docs/spec/06: the 500-cap on timeline pages).
    public static let maxPageLimit = 500

    // MARK: - Event observers (the one in-process bus)

    /// Called AFTER an events row commits, for every append path on this store
    /// (appendEvent, scans, quarantine, retention marker). The API server hooks
    /// its `event.appended` fanout here (02: "Every append fans out over
    /// event.appended to subscribed connections"), so the collector/analyzer,
    /// the scan orchestrator, and API mutations all share ONE bus.
    public typealias EventObserver = @Sendable (StoredEvent) -> Void

    private let observerLock = NSLock()
    private var observers: [EventObserver] = []

    /// Register an observer for every committed event append on this store.
    public func addEventObserver(_ observer: @escaping EventObserver) {
        observerLock.lock(); defer { observerLock.unlock() }
        observers.append(observer)
    }

    /// Deliver a committed event to every observer (outside the lock, so a slow
    /// sink can never deadlock a writer).
    func notifyObservers(_ event: StoredEvent) {
        observerLock.lock()
        let targets = observers
        observerLock.unlock()
        for observer in targets { observer(event) }
    }

    /// Open (and migrate) the store at `path`. Pass ":memory:" for an in-memory
    /// database in tests; a real file path enables WAL on disk.
    public init(path: String, ulid: ULIDGenerator = ULIDGenerator()) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // FK enforcement is a PRAGMA (06); WAL is the journaling mode. Both
            // run before any transaction on each new connection.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Another process (or a second store instance in tests) briefly
            // holding the write lock waits instead of failing.
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        self.ulid = ulid
        try PlugsightSchema.migrator.migrate(dbQueue)
    }

    // MARK: - Write: events (the only history write path)

    /// Append a history row. Generates 'evt_' + ULID and stores the rendered
    /// `summary` string as given (06: the summary is frozen at write time).
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
    ) throws -> String {
        try appendStoredEvent(kind: kind, severity: severity, deviceID: deviceID,
                              actor: actor, summary: summary, detail: detail,
                              alertID: alertID, at: now).id
    }

    /// Append a history row and return the full stored event (so callers can
    /// quote it and the observers can fan it out).
    @discardableResult
    public func appendStoredEvent(
        kind: String,
        severity: String,
        deviceID: String? = nil,
        actor: String = "system",
        summary: String,
        detail: String = "{}",
        alertID: String? = nil,
        at now: Date = Date()
    ) throws -> StoredEvent {
        let id = "evt_" + ulid.next(now: now)
        let at = ISO8601Millis.string(now)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO events (id, at, kind, severity, device_id, actor, summary, detail, alert_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, at, kind, severity, deviceID, actor, summary, detail, alertID]
            )
        }
        let event = StoredEvent(id: id, at: at, kind: kind, severity: severity,
                                deviceID: deviceID, actor: actor, summary: summary,
                                detail: detail, alertID: alertID)
        notifyObservers(event)
        return event
    }

    // MARK: - Write: device upsert by identity

    /// Create-or-touch a device from raw collector facts. Computes the stable
    /// identity (06), inserts a new row + its device_interfaces on first sight,
    /// or updates last_seen_at/present on a re-attach match.
    @discardableResult
    public func upsertDevice(from d: DeviceDescriptor, at now: Date = Date()) throws -> UpsertResult {
        let identity = DeviceIdentifier.compute(
            vid: d.vid, pid: d.pid, serial: d.serial,
            vendorName: d.vendorName, productName: d.productName,
            interfaces: d.interfaces
        )
        let at = ISO8601Millis.string(now)

        return try dbQueue.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT id FROM devices WHERE identity_key = ?",
                arguments: [identity.key]
            ) {
                let id: String = existing["id"]
                try db.execute(
                    sql: "UPDATE devices SET last_seen_at = ?, present = 1 WHERE id = ?",
                    arguments: [at, id]
                )
                return UpsertResult(deviceID: id, isNew: false)
            }

            let id = "dev_" + ulid.next(now: now)
            let display = Self.displayName(productName: d.productName, interfaces: d.interfaces)
            try db.execute(
                sql: """
                INSERT INTO devices
                  (id, identity_key, identity_basis, vid, pid, serial, vendor_name, product_name,
                   display_name, first_seen_at, last_seen_at, present, trust_tier,
                   trust_note, trust_set_by, trust_set_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'none', NULL, NULL, NULL)
                """,
                arguments: [
                    id, identity.key, identity.basis, d.vid, d.pid, d.serial,
                    d.vendorName, d.productName, display, at, at
                ]
            )
            for iface in d.interfaces.sorted(by: { $0.seq < $1.seq }) {
                try db.execute(
                    sql: """
                    INSERT INTO device_interfaces
                      (device_id, seq, usb_class, usb_subclass, usb_protocol, role)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [id, iface.seq, iface.usbClass, iface.usbSubclass, iface.usbProtocol, Self.role(for: iface)]
                )
            }
            return UpsertResult(deviceID: id, isNew: true)
        }
    }

    // MARK: - Read: events

    /// Newest-first, cursor-paginated events. Cursor pagination uses
    /// `WHERE id < ?` (ULIDs are time-ordered, so id order == time order), which
    /// stays STABLE across pages even as new events append: a newer event has a
    /// larger id and never shifts an in-progress older-than-cursor page.
    public func listEvents(
        filter: EventFilter = EventFilter(),
        limit: Int = maxPageLimit,
        cursor: String? = nil
    ) throws -> [StoredEvent] {
        let lim = min(max(limit, 1), Self.maxPageLimit)
        var conditions: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if let deviceID = filter.deviceID {
            conditions.append("device_id = ?")
            args.append(deviceID)
        }
        if let kind = filter.kind {
            conditions.append("kind = ?")
            args.append(kind)
        }
        if let cursor {
            conditions.append("id < ?")
            args.append(cursor)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        args.append(lim)

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, at, kind, severity, device_id, actor, summary, detail, alert_id
                FROM events
                \(whereClause)
                ORDER BY id DESC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.map(Self.event(from:))
        }
    }

    // MARK: - Read: devices

    /// Newest-first (by device id), cursor-paginated device summaries.
    public func listDevices(
        filter: DeviceFilter = DeviceFilter(),
        limit: Int = maxPageLimit,
        cursor: String? = nil
    ) throws -> [StoredDevice] {
        let lim = min(max(limit, 1), Self.maxPageLimit)
        var conditions: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if filter.presentOnly {
            conditions.append("present = 1")
        }
        if let tier = filter.trustTier {
            conditions.append("trust_tier = ?")
            args.append(tier)
        }
        if let cursor {
            conditions.append("id < ?")
            args.append(cursor)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        args.append(lim)

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM devices \(whereClause) ORDER BY id DESC LIMIT ?",
                arguments: StatementArguments(args)
            )
            return try rows.map { try Self.device(from: $0, db: db) }
        }
    }

    /// Full device record (with interfaces), or nil if not found.
    public func getDevice(id: String) throws -> StoredDevice? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM devices WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try Self.device(from: row, db: db)
        }
    }

    // MARK: - Retention

    /// Delete events, score snapshots, and scan rows (with their findings)
    /// older than the cutoff, then append ONE marker event summarizing the
    /// pruned range (06: "Pruning writes a single marker event summarizing what
    /// range was pruned"). Devices and alerts are kept indefinitely — the
    /// durable dossier. Returns the number of events deleted. If nothing was
    /// old enough, no marker is written.
    @discardableResult
    public func pruneRetention(olderThanDays days: Int, at now: Date = Date()) throws -> Int {
        let cutoffDate = now.addingTimeInterval(-Double(days) * 86_400)
        let cutoff = ISO8601Millis.string(cutoffDate)

        let (deletedEvents, marker): (Int, StoredEvent?) = try dbQueue.write { db in
            let range = try Row.fetchOne(
                db,
                sql: "SELECT MIN(at) AS lo, MAX(at) AS hi, COUNT(*) AS n FROM events WHERE at < ?",
                arguments: [cutoff]
            )
            let count: Int = range?["n"] ?? 0
            let lo: String? = range?["lo"]
            let hi: String? = range?["hi"]

            try db.execute(sql: "DELETE FROM events WHERE at < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM score_snapshots WHERE at < ?", arguments: [cutoff])

            // Scan rows age out with the same window (retentionDays was inert
            // for scans before Wave 1b). Findings go first (FK hygiene).
            let scanRange = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS n FROM scans WHERE started_at < ?",
                arguments: [cutoff]
            )
            let scanCount: Int = scanRange?["n"] ?? 0
            try db.execute(
                sql: "DELETE FROM scan_findings WHERE scan_id IN (SELECT id FROM scans WHERE started_at < ?)",
                arguments: [cutoff]
            )
            try db.execute(sql: "DELETE FROM scans WHERE started_at < ?", arguments: [cutoff])

            guard count > 0, let lo, let hi else { return (0, nil) }

            let markerID = "evt_" + ulid.next(now: now)
            var summary = "Pruned \(count) event(s) from \(lo) to \(hi) (retention: \(days) days)."
            if scanCount > 0 { summary += " Also pruned \(scanCount) scan record(s)." }
            let detail = "{\"v\":1,\"pruned_from\":\"\(lo)\",\"pruned_to\":\"\(hi)\",\"count\":\(count),\"scans\":\(scanCount)}"
            try db.execute(
                sql: """
                INSERT INTO events (id, at, kind, severity, device_id, actor, summary, detail, alert_id)
                VALUES (?, ?, 'monitoring.gap', 'notice', NULL, 'system', ?, ?, NULL)
                """,
                arguments: [markerID, ISO8601Millis.string(now), summary, detail]
            )
            let marker = StoredEvent(id: markerID, at: ISO8601Millis.string(now),
                                     kind: "monitoring.gap", severity: "notice",
                                     deviceID: nil, actor: "system", summary: summary,
                                     detail: detail, alertID: nil)
            return (count, marker)
        }
        if let marker { notifyObservers(marker) }
        return deletedEvents
    }

    // MARK: - Testing hook

    /// Read-only database access for tests (schema introspection). Not part of
    /// the public write surface.
    func withDatabaseForTesting<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    // MARK: - Row mapping

    private static func event(from row: Row) -> StoredEvent {
        StoredEvent(
            id: row["id"],
            at: row["at"],
            kind: row["kind"],
            severity: row["severity"],
            deviceID: row["device_id"],
            actor: row["actor"],
            summary: row["summary"],
            detail: row["detail"],
            alertID: row["alert_id"]
        )
    }

    private static func device(from row: Row, db: Database) throws -> StoredDevice {
        let id: String = row["id"]
        let interfaceRows = try Row.fetchAll(
            db,
            sql: "SELECT seq, usb_class, usb_subclass, usb_protocol, role FROM device_interfaces WHERE device_id = ? ORDER BY seq",
            arguments: [id]
        )
        let interfaces = interfaceRows.map {
            StoredInterface(
                seq: $0["seq"],
                usbClass: $0["usb_class"],
                usbSubclass: $0["usb_subclass"],
                usbProtocol: $0["usb_protocol"],
                role: $0["role"]
            )
        }
        let present: Int = row["present"]
        return StoredDevice(
            id: id,
            identityKey: row["identity_key"],
            identityBasis: row["identity_basis"],
            vid: row["vid"],
            pid: row["pid"],
            serial: row["serial"],
            vendorName: row["vendor_name"],
            productName: row["product_name"],
            displayName: row["display_name"],
            firstSeenAt: row["first_seen_at"],
            lastSeenAt: row["last_seen_at"],
            present: present != 0,
            trustTier: row["trust_tier"],
            trustNote: row["trust_note"],
            trustSetBy: row["trust_set_by"],
            trustSetAt: row["trust_set_at"],
            interfaces: interfaces
        )
    }

    // MARK: - Display name & role derivation

    /// display_name = product_name if non-empty, else a class-derived fallback
    /// from the interface roles, else "USB device".
    static func displayName(productName: String?, interfaces: [InterfaceDescriptor]) -> String {
        if let name = productName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let roles = Set(interfaces.map { role(for: $0) })
        if roles.contains("keyboard") { return "USB keyboard" }
        if roles.contains("mouse") { return "USB mouse" }
        if roles.contains("storage") { return "USB storage device" }
        if roles.contains("network") { return "USB network adapter" }
        if roles.contains("audio") { return "USB audio device" }
        if roles.contains("video") { return "USB video device" }
        if roles.contains("smartcard") { return "USB smart card" }
        if roles.contains("hub") { return "USB hub" }
        return "USB device"
    }

    /// Map a USB interface class code to one of 06's role words.
    static func role(for iface: InterfaceDescriptor) -> String {
        switch iface.usbClass {
        case 0x01: return "audio"
        case 0x02, 0x0A: return "network"       // Communications / CDC-Data
        case 0x03:                               // HID: distinguish by protocol
            switch iface.usbProtocol {
            case 1: return "keyboard"
            case 2: return "mouse"
            default: return "other"
            }
        case 0x08: return "storage"              // Mass Storage
        case 0x09: return "hub"
        case 0x0B: return "smartcard"
        case 0x0E: return "video"
        case 0xE0: return "network"              // Wireless Controller (e.g. RNDIS)
        case 0xFF: return "vendor"
        default: return "other"
        }
    }
}

/// ISO-8601 UTC timestamps with millisecond precision (06: "ISO-8601 UTC,
/// milliseconds"). Time strings sort lexicographically in chronological order.
enum ISO8601Millis {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
