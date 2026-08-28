import XCTest
@testable import PlugsightAppCore

@MainActor
final class TimelineViewModelTests: XCTestCase {

    func testNormalLoadsRows() async {
        let vm = TimelineViewModel(api: FakeAPIClient())
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded, got \(vm.state)") }
        XCTAssertFalse(l.isEmpty)
        XCTAssertNil(l.emptySentence)
    }

    // Two empty states split by the filter predicate (data honesty).
    func testEmptyNoFiltersSentence() async {
        let fake = FakeAPIClient()
        fake.timelineResult = .success(Canned.timelineEmpty)
        let vm = TimelineViewModel(api: fake)
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.isEmpty)
        XCTAssertFalse(l.filtersActive)
        XCTAssertEqual(l.emptySentence, "No events yet. Plug something in and it will appear here.")
        XCTAssertFalse(l.showsClearFilters)
    }

    func testEmptyWithFiltersSentenceAndClear() async {
        let fake = FakeAPIClient()
        fake.timelineResult = .success(Canned.timelineEmpty)
        let vm = TimelineViewModel(api: fake)
        vm.filters = TimelineFilters(severity: "critical")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.isEmpty)
        XCTAssertTrue(l.filtersActive)
        XCTAssertEqual(l.emptySentence, "No events match these filters")
        XCTAssertTrue(l.showsClearFilters)
    }

    func testStoreError() async {
        let fake = FakeAPIClient()
        fake.timelineResult = .failure(APIError(kind: .storeUnreadable, message: "Can't read the event record"))
        let vm = TimelineViewModel(api: fake)
        await vm.load()
        guard case .storeError(let msg) = vm.state else { return XCTFail("expected storeError") }
        XCTAssertEqual(msg, "Can't read the event record")
    }

    // At-scale: day headers + an inline monitoring-gap row.
    func testAtScaleHasDayHeadersAndGapRow() {
        let rows = TimelineViewModel.rows(from: Canned.timelineAtScale)
        let hasHeader = rows.contains { if case .dayHeader = $0 { return true } else { return false } }
        let hasGap = rows.contains { if case .gap = $0 { return true } else { return false } }
        XCTAssertTrue(hasHeader, "expected day-header rows at scale")
        XCTAssertTrue(hasGap, "expected an inline monitoring-gap row")
    }

    func testGapCarriesReadableWindow() {
        let rows = TimelineViewModel.rows(from: Canned.timelineAtScale)
        // The gap row renders a monitoring.gap EVENT; its readable window lives in
        // the event summary (06), not a separate from/to field.
        let gap = rows.compactMap { row -> EventDTO? in
            if case .gap(let e) = row { return e } else { return nil }
        }.first
        let gapEvent = try? XCTUnwrap(gap)
        XCTAssertEqual(gapEvent?.kind, "monitoring.gap")
        XCTAssertTrue(gapEvent?.summary.contains("Monitoring was off") ?? false)
    }

    // Day headers are humanized (never a raw ISO date): Today / Yesterday / medium.
    func testDayHeaderIsHumanizedNotRawISO() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12))!
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(TimelineViewModel.dayHeaderLabel(forISODay: "2026-08-26", now: now, locale: posix), "Today")
        XCTAssertEqual(TimelineViewModel.dayHeaderLabel(forISODay: "2026-08-25", now: now, locale: posix), "Yesterday")
        let older = TimelineViewModel.dayHeaderLabel(forISODay: "2026-08-20", now: now, locale: posix)
        XCTAssertNotEqual(older, "2026-08-20", "older days must not render the raw ISO date")
        XCTAssertTrue(older.contains("2026"), "medium date still names the year")
    }

    // Rows produced through the humanizer carry no raw ISO day-header text.
    func testRowsHeadersAreHumanized() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12))!
        let rows = TimelineViewModel.rows(from: Canned.timelineNormal, now: now)
        let headers = rows.compactMap { row -> String? in
            if case .dayHeader(let d) = row { return d } else { return nil }
        }
        XCTAssertFalse(headers.isEmpty)
        for h in headers { XCTAssertNotEqual(h, "2026-08-25", "header must be humanized, not raw ISO") }
    }
}
