// StoreTests.swift
//
// N2 store behaviors (docs/spec/07), one test per behavior:
//   1. migration produces the 06 schema (introspect sqlite_master / pragmas)
//   2. device upsert by identity key — serial case and shape-fingerprint case,
//      including two identical serialless sticks collapsing to one row
//   3. appendEvent is the only write path for history
//   4. cursor pagination is stable newest-first across pages
//   5. retention prune writes the marker event
// Plus ULID ordering (the store's cursor depends on it).

import XCTest
import Foundation
import GRDB
@testable import PlugsightCore

final class StoreTests: XCTestCase {

    // A fresh on-disk store in a unique temp dir, so WAL applies on a real file.
    private func makeStore(ulid: ULIDGenerator = ULIDGenerator()) throws -> (EventStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugsight-n2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("plugsight.sqlite").path
        return (try EventStore(path: path, ulid: ulid), dir)
    }

    private func descriptor(
        deviceKey: String = "k",
        vid: Int = 0x1234,
        pid: Int = 0x5678,
        serial: String? = nil,
        vendorName: String? = "Acme",
        productName: String? = "Ultra Stick",
        interfaces: [InterfaceDescriptor] = [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 0x06, usbProtocol: 0x50)]
    ) -> DeviceDescriptor {
        DeviceDescriptor(
            deviceKey: deviceKey, vid: vid, pid: pid, serial: serial,
            vendorName: vendorName, productName: productName,
            interfaces: interfaces, portPath: nil
        )
    }

    // MARK: - ULID ordering (cursor depends on it)

    func testULIDsSortInCreationOrder() {
        let gen = ULIDGenerator()
        var ids: [String] = []
        // Same-millisecond burst must still be strictly increasing (monotonic).
        let now = Date()
        for _ in 0..<1000 { ids.append(gen.next(now: now)) }
        XCTAssertEqual(ids, ids.sorted(), "ULIDs minted in order must sort in that order")
        XCTAssertEqual(Set(ids).count, ids.count, "ULIDs must be unique")
        XCTAssertTrue(ids.allSatisfy { $0.count == 26 }, "ULIDs are 26 chars")
    }

    // MARK: - 1. Migration produces the 06 schema

    func testMigrationProducesFrozenSchema() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.withDatabaseForTesting { db in
            // All nine tables exist.
            let tables = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
                .map { $0["name"] as String }
            for expected in ["alerts", "device_interfaces", "devices", "events", "policy", "scan_findings", "scans", "score_snapshots"] {
                XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
            }

            // devices columns, order, types, notnull, pk transcribed verbatim.
            assertColumns(db, table: "devices", expected: [
                ("id", "TEXT", false, true),
                ("identity_key", "TEXT", true, false),
                ("identity_basis", "TEXT", true, false),
                ("vid", "INTEGER", true, false),
                ("pid", "INTEGER", true, false),
                ("serial", "TEXT", false, false),
                ("vendor_name", "TEXT", false, false),
                ("product_name", "TEXT", false, false),
                ("display_name", "TEXT", true, false),
                ("first_seen_at", "TEXT", true, false),
                ("last_seen_at", "TEXT", true, false),
                ("present", "INTEGER", true, false),
                ("trust_tier", "TEXT", true, false),
                ("trust_note", "TEXT", false, false),
                ("trust_set_by", "TEXT", false, false),
                ("trust_set_at", "TEXT", false, false),
            ])

            // events columns, order, types.
            assertColumns(db, table: "events", expected: [
                ("id", "TEXT", false, true),
                ("at", "TEXT", true, false),
                ("kind", "TEXT", true, false),
                ("severity", "TEXT", true, false),
                ("device_id", "TEXT", false, false),
                ("actor", "TEXT", true, false),
                ("summary", "TEXT", true, false),
                ("detail", "TEXT", true, false),
                ("alert_id", "TEXT", false, false),
            ])

            // device_interfaces has a composite primary key (device_id, seq).
            let diPk = try Row.fetchAll(db, sql: "PRAGMA table_info(device_interfaces)")
                .filter { ($0["pk"] as Int) > 0 }
                .sorted { ($0["pk"] as Int) < ($1["pk"] as Int) }
                .map { $0["name"] as String }
            XCTAssertEqual(diPk, ["device_id", "seq"])

            // CHECK constraints survive in the stored DDL.
            let devicesSQL = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name='devices'") ?? ""
            XCTAssertTrue(devicesSQL.contains("identity_basis IN ('serial','shape')"))
            XCTAssertTrue(devicesSQL.contains("trust_tier IN ('none','trusted','muted','flagged')"))
            let eventsSQL = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name='events'") ?? ""
            XCTAssertTrue(eventsSQL.contains("severity IN ('info','notice','warning','critical')"))

            // The three events indexes plus scores index exist.
            let indexes = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND sql IS NOT NULL")
                .map { $0["name"] as String }
            for idx in ["idx_events_at", "idx_events_device", "idx_events_kind", "idx_scores_device"] {
                XCTAssertTrue(indexes.contains(idx), "missing index \(idx)")
            }
        }
    }

    private func assertColumns(_ db: Database, table: String, expected: [(String, String, Bool, Bool)], file: StaticString = #file, line: UInt = #line) {
        do {
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            let actual = rows.map { row -> (String, String, Bool, Bool) in
                (row["name"], row["type"], (row["notnull"] as Int) != 0, (row["pk"] as Int) != 0)
            }
            XCTAssertEqual(actual.count, expected.count, "\(table) column count", file: file, line: line)
            for (a, e) in zip(actual, expected) {
                XCTAssertEqual(a.0, e.0, "\(table) column name", file: file, line: line)
                XCTAssertEqual(a.1, e.1, "\(table).\(a.0) type", file: file, line: line)
                XCTAssertEqual(a.2, e.2, "\(table).\(a.0) notnull", file: file, line: line)
                XCTAssertEqual(a.3, e.3, "\(table).\(a.0) pk", file: file, line: line)
            }
        } catch {
            XCTFail("PRAGMA table_info(\(table)) failed: \(error)", file: file, line: line)
        }
    }

    // MARK: - 2. Device upsert by identity key

    func testUpsertSerialIdentity() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let d = descriptor(serial: "SN-ABCDEF-01")
        let first = try store.upsertDevice(from: d)
        XCTAssertTrue(first.isNew)

        // Re-attach the same serialled device -> same row, not new.
        let again = try store.upsertDevice(from: d)
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(first.deviceID, again.deviceID)

        let stored = try XCTUnwrap(store.getDevice(id: first.deviceID))
        XCTAssertEqual(stored.identityBasis, "serial")
        XCTAssertEqual(stored.identityKey, "serial:\(d.vid):\(d.pid):SN-ABCDEF-01")
        XCTAssertTrue(stored.present)

        // Exactly one row.
        XCTAssertEqual(try store.listDevices().count, 1)
    }

    func testTrivialSerialFallsBackToShape() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Serial "000" (all zeros / <=3 chars) is trivial -> shape basis.
        let d = descriptor(serial: "000")
        let r = try store.upsertDevice(from: d)
        let stored = try XCTUnwrap(store.getDevice(id: r.deviceID))
        XCTAssertEqual(stored.identityBasis, "shape")
        XCTAssertTrue(stored.identityKey.hasPrefix("shape:"))
    }

    func testTwoIdenticalSeriallessSticksCollapseToOneRow() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two serialless sticks with identical shape (vid, pid, interfaces,
        // descriptor strings) but DIFFERENT transient deviceKeys.
        let a = descriptor(deviceKey: "keyA", serial: nil)
        let b = descriptor(deviceKey: "keyB", serial: nil)

        let ra = try store.upsertDevice(from: a)
        let rb = try store.upsertDevice(from: b)

        XCTAssertTrue(ra.isNew)
        XCTAssertFalse(rb.isNew, "identical serialless sticks must collapse to one row")
        XCTAssertEqual(ra.deviceID, rb.deviceID)
        XCTAssertEqual(try store.listDevices().count, 1)

        let stored = try XCTUnwrap(store.getDevice(id: ra.deviceID))
        XCTAssertEqual(stored.identityBasis, "shape")

        // A DIFFERENT shape (extra interface) must NOT collapse.
        let c = descriptor(
            deviceKey: "keyC",
            serial: nil,
            interfaces: [
                InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 0x06, usbProtocol: 0x50),
                InterfaceDescriptor(seq: 1, usbClass: 0x03, usbSubclass: 0x01, usbProtocol: 0x01),
            ]
        )
        let rc = try store.upsertDevice(from: c)
        XCTAssertTrue(rc.isNew)
        XCTAssertEqual(try store.listDevices().count, 2)
    }

    func testUpsertPersistsInterfacesAndDisplayName() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Serialless keyboard with empty product name -> class-derived display.
        let d = descriptor(
            serial: nil,
            productName: "  ",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0x01, usbProtocol: 0x01)]
        )
        let r = try store.upsertDevice(from: d)
        let stored = try XCTUnwrap(store.getDevice(id: r.deviceID))
        XCTAssertEqual(stored.displayName, "USB keyboard")
        XCTAssertEqual(stored.interfaces.count, 1)
        XCTAssertEqual(stored.interfaces[0].role, "keyboard")
    }

    // MARK: - 3. appendEvent is the only write path for history

    func testAppendEventWritesHistoryRow() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try store.appendEvent(
            kind: "device.attached",
            severity: "info",
            summary: "SanDisk Ultra plugged in. Presents as: storage."
        )
        XCTAssertTrue(id.hasPrefix("evt_"))

        let events = try store.listEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, id)
        XCTAssertEqual(events[0].kind, "device.attached")
        XCTAssertEqual(events[0].severity, "info")
        XCTAssertEqual(events[0].actor, "system")            // default
        XCTAssertEqual(events[0].detail, "{}")               // default
        // The rendered summary is frozen at write time.
        XCTAssertEqual(events[0].summary, "SanDisk Ultra plugged in. Presents as: storage.")
    }

    func testEventFilterByKindAndDevice() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dev = try store.upsertDevice(from: descriptor(serial: "SN-FILTER-1"))
        try store.appendEvent(kind: "device.attached", severity: "info", deviceID: dev.deviceID, summary: "a")
        try store.appendEvent(kind: "hid.typing_burst", severity: "notice", deviceID: dev.deviceID, summary: "b")
        try store.appendEvent(kind: "daemon.started", severity: "info", summary: "c")

        XCTAssertEqual(try store.listEvents(filter: EventFilter(kind: "device.attached")).count, 1)
        XCTAssertEqual(try store.listEvents(filter: EventFilter(deviceID: dev.deviceID)).count, 2)
    }

    // MARK: - 4. Cursor pagination is stable newest-first across pages

    func testCursorPaginationStableNewestFirst() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let total = 47
        let pageSize = 10
        var appended: [String] = []
        // Append with strictly increasing timestamps so id order == time order.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<total {
            let id = try store.appendEvent(
                kind: "device.attached", severity: "info",
                summary: "e\(i)", at: base.addingTimeInterval(Double(i))
            )
            appended.append(id)
        }
        let newestFirst = appended.reversed().map { $0 }

        // Page through; after the first page, append a NEW event mid-pagination.
        var seen: [String] = []
        var cursor: String? = nil
        var injectedAfterFirstPage = false
        while true {
            let page = try store.listEvents(limit: pageSize, cursor: cursor)
            if page.isEmpty { break }

            // Newest-first within the page.
            let pageIDs = page.map { $0.id }
            XCTAssertEqual(pageIDs, pageIDs.sorted(by: >), "page not newest-first")

            seen.append(contentsOf: pageIDs)
            cursor = pageIDs.last

            if !injectedAfterFirstPage {
                injectedAfterFirstPage = true
                // A newer event (larger id) appears mid-pagination. It must not
                // duplicate or skip any of the original 47 in the remaining pages.
                _ = try store.appendEvent(
                    kind: "device.attached", severity: "info",
                    summary: "late", at: base.addingTimeInterval(Double(total + 100))
                )
            }
        }

        // Every original event seen exactly once, in newest-first order.
        XCTAssertEqual(seen, newestFirst, "each event exactly once, newest-first, stable across pages")
        XCTAssertEqual(Set(seen).count, seen.count, "no duplicates")
    }

    // MARK: - 5. Retention prune writes the marker event

    func testPruneWritesMarkerEvent() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Old events (400 days ago) + recent events (1 day ago).
        for i in 0..<5 {
            try store.appendEvent(kind: "device.attached", severity: "info", summary: "old\(i)",
                                  at: now.addingTimeInterval(-400 * 86_400 + Double(i)))
        }
        for i in 0..<3 {
            try store.appendEvent(kind: "device.attached", severity: "info", summary: "recent\(i)",
                                  at: now.addingTimeInterval(-1 * 86_400 + Double(i)))
        }

        let deleted = try store.pruneRetention(olderThanDays: 365, at: now)
        XCTAssertEqual(deleted, 5, "the 5 old events are pruned")

        let events = try store.listEvents(limit: 500)
        // 3 recent + 1 marker.
        XCTAssertEqual(events.count, 4)
        let markers = events.filter { $0.kind == "monitoring.gap" }
        XCTAssertEqual(markers.count, 1, "exactly one marker event")
        XCTAssertEqual(markers[0].severity, "notice")
        XCTAssertTrue(markers[0].summary.contains("Pruned 5 event"))

        // None of the old events survive.
        XCTAssertFalse(events.contains { $0.summary.hasPrefix("old") })
        XCTAssertTrue(events.contains { $0.summary == "recent0" })
    }

    func testPruneWithNothingOldWritesNoMarker() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.appendEvent(kind: "daemon.started", severity: "info", summary: "fresh", at: now)
        let deleted = try store.pruneRetention(olderThanDays: 365, at: now)
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(try store.listEvents().count, 1, "no marker when nothing was pruned")
    }
}
