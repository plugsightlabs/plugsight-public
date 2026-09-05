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

    /// The catalog is exactly 20 kinds: the 06 table minus the three kinds
    /// that still have NO emit site (device.interfaces_changed,
    /// esext.iokit_open, alert.resolved — Wave 1b catalog honesty).
    /// volume.held / volume.released returned in Wave 4: the mount-hold
    /// coordinator emits both. Bump this only alongside a matching README /
    /// docs update — the drift gate enforces the same.
    func testCatalogHasExactlyTheV1Count() {
        XCTAssertEqual(EventKindCatalog.all.count, 20)
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
            "alert.raised", "alert.acknowledged",
            "quarantine.restored", "monitoring.gap", "daemon.started", "daemon.stopped",
            "volume.held", "volume.released",
        ] {
            XCTAssertTrue(EventKindCatalog.all.contains(expected), "catalog is missing \(expected)")
        }
    }

    /// Catalog honesty (Wave 1b): kinds with zero emit sites stay OUT of the
    /// closed set until something actually emits them, so the README and the
    /// UI can never advertise events that cannot occur. (volume.held and
    /// volume.released left this list in Wave 4: MountHoldCoordinator emits
    /// them.)
    func testCatalogOmitsKindsWithNoEmitSite() {
        for phantom in [
            "device.interfaces_changed",
            "esext.iokit_open", "alert.resolved",
        ] {
            XCTAssertFalse(EventKindCatalog.all.contains(phantom),
                           "\(phantom) has no emit site and must not be advertised")
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
