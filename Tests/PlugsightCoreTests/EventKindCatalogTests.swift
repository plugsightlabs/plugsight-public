// EventKindCatalogTests.swift
//
// Pins the canonical v1 event-kind catalog (docs/spec/06). The N14 drift gate
// reads this exact set via `plugsightd --print-catalog`, so a silent edit here
// would silently move what the gate treats as truth. These tests make such an
// edit a deliberate, reviewed act: the count is asserted, and the printed JSON
// is asserted to carry the whole set, sorted, with a matching count field.

import XCTest
@testable import PlugsightCore

final class EventKindCatalogTests: XCTestCase {

    /// The v1 catalog is exactly 23 kinds (06). Bump this only alongside a
    /// matching README / docs update — the drift gate enforces the same.
    func testCatalogHasExactlyTheV1Count() {
        XCTAssertEqual(EventKindCatalog.all.count, 23)
    }

    /// No duplicates: the catalog is a set expressed as an ordered list.
    func testCatalogHasNoDuplicates() {
        XCTAssertEqual(Set(EventKindCatalog.all).count, EventKindCatalog.all.count)
    }

    /// Every kind is namespaced (06: "Kinds are namespaced"): `prefix.suffix`,
    /// lowercase, with exactly one dot separating two non-empty segments.
    func testEveryKindIsNamespaced() {
        for kind in EventKindCatalog.all {
            let parts = kind.split(separator: ".", omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 2, "kind \(kind) is not `prefix.suffix`")
            XCTAssertFalse(parts.contains(where: \.isEmpty), "kind \(kind) has an empty segment")
            XCTAssertEqual(kind, kind.lowercased(), "kind \(kind) is not lowercase")
        }
    }

    /// The catalog contains the load-bearing lifecycle + honesty kinds that other
    /// specs (06/08) name explicitly, so a rename can't quietly drop them.
    func testCatalogContainsTheNamedAnchors() {
        for expected in [
            "device.attached", "mismatch.detected", "score.changed",
            "alert.raised", "alert.acknowledged", "alert.resolved",
            "quarantine.restored", "monitoring.gap", "daemon.started", "daemon.stopped",
        ] {
            XCTAssertTrue(EventKindCatalog.all.contains(expected), "catalog is missing \(expected)")
        }
    }

    /// The printable JSON — exactly what `--print-catalog` emits — is valid JSON,
    /// carries every kind sorted, and its declared count matches.
    func testPrintableJSONCarriesTheWholeSetSortedWithMatchingCount() throws {
        let data = Data(EventKindCatalog.printableJSON().utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let kinds = try XCTUnwrap(object?["eventKinds"] as? [String])
        let count = try XCTUnwrap(object?["eventKindCount"] as? Int)

        XCTAssertEqual(count, EventKindCatalog.all.count)
        XCTAssertEqual(kinds.count, EventKindCatalog.all.count)
        XCTAssertEqual(Set(kinds), Set(EventKindCatalog.all))
        XCTAssertEqual(kinds, kinds.sorted(), "printed kinds must be deterministically sorted")
    }
}
