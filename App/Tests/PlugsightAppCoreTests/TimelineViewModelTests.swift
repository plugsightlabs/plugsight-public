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
    }

    // The one real filter (04): Alerts only reads the ACTIVE alerts and renders
    // them through the same day-grouped rows.
    func testAlertsOnlyLoadsActiveAlertsAsRows() async {
        let vm = TimelineViewModel(api: FakeAPIClient())
        vm.filters.activeAlertsOnly = true
        await vm.load(now: Canned.timelineReferenceNow)
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.alertsOnly)
        XCTAssertFalse(l.isEmpty)
        let events = l.rows.compactMap { row -> EventDTO? in
            if case .event(let e) = row { return e } else { return nil }
        }
        XCTAssertEqual(events.map(\.eventId), ["alt_1"], "alert rows carry the alert id")
        XCTAssertEqual(events.first?.summary, Canned.alertsOne.alerts[0].summary)
    }

    // Empty alerts-only view reads as good news AND names the filter, so an
    // empty list is never mistaken for an empty history.
    func testAlertsOnlyEmptySentence() async {
        let fake = FakeAPIClient(alerts: .success(Canned.alertsEmpty))
        let vm = TimelineViewModel(api: fake)
        vm.filters.activeAlertsOnly = true
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.isEmpty)
        XCTAssertEqual(l.emptySentence, "No active alerts. The Alerts only filter is on.")
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

    // Day headers are humanized (never a raw ISO date): Today / Yesterday / a
    // fixed-English medium date (no mixed-language rows).
    func testDayHeaderIsHumanizedNotRawISO() {
        let utcZone = TimeZone(identifier: "UTC")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = utcZone
        let now = utc.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12))!
        XCTAssertEqual(TimelineViewModel.dayHeaderLabel(forISODay: "2026-08-26", now: now, timeZone: utcZone), "Today")
        XCTAssertEqual(TimelineViewModel.dayHeaderLabel(forISODay: "2026-08-25", now: now, timeZone: utcZone), "Yesterday")
        let older = TimelineViewModel.dayHeaderLabel(forISODay: "2026-08-20", now: now, timeZone: utcZone)
        XCTAssertEqual(older, "Aug 20, 2026", "older days render a fixed-English medium date, never raw ISO")
    }

    // Rows produced through the humanizer carry no raw ISO day-header text.
    func testRowsHeadersAreHumanized() {
        let utcZone = TimeZone(identifier: "UTC")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = utcZone
        let now = utc.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12))!
        let rows = TimelineViewModel.rows(from: Canned.timelineNormal, now: now, timeZone: utcZone)
        let headers = rows.compactMap { row -> String? in
            if case .dayHeader(let d) = row { return d } else { return nil }
        }
        XCTAssertFalse(headers.isEmpty)
        for h in headers { XCTAssertNotEqual(h, "2026-08-25", "header must be humanized, not raw ISO") }
    }

    // Timezone honesty: day grouping happens in the VIEWER'S timezone, not UTC.
    // An event at 23:30Z belongs to the NEXT local day at UTC+2 and reads Today.
    func testRowsGroupByLocalDayNotUTCDay() {
        let plusTwo = TimeZone(secondsFromGMT: 2 * 3600)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = plusTwo
        // Local now: Aug 26, 12:00 at UTC+2.
        let now = cal.date(from: DateComponents(timeZone: plusTwo, year: 2026, month: 8, day: 26, hour: 12))!
        let timeline = TimelineDTO(events: [
            EventDTO(eventId: "e1", at: "2026-08-25T23:30:00Z", kind: "device.attached",
                     severity: "info", deviceId: "dev_1", summary: "Late-night plug-in.", actor: "system"),
            EventDTO(eventId: "e2", at: "2026-08-25T10:00:00Z", kind: "device.detached",
                     severity: "info", deviceId: "dev_1", summary: "Morning unplug.", actor: "system"),
        ], nextCursor: nil)
        let rows = TimelineViewModel.rows(from: timeline, now: now, timeZone: plusTwo)
        let headers = rows.compactMap { row -> String? in
            if case .dayHeader(let d) = row { return d } else { return nil }
        }
        // 23:30Z on Aug 25 is 01:30 local Aug 26 ("Today"); 10:00Z stays Aug 25
        // local ("Yesterday"). UTC grouping would have collapsed both into one day.
        XCTAssertEqual(headers, ["Today", "Yesterday"])
    }
}
