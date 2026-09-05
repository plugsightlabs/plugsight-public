// GapVocabularyTests.swift
//
// Gap rows must read as local wall-clock text (live-walk defect 6): the
// daemon's summary embeds raw UTC ISO stamps; the UI formats the structured
// detail window in the viewer's timezone and falls back to the raw summary
// only when the detail is unusable.

import XCTest
@testable import PlugsightAppCore

final class GapVocabularyTests: XCTestCase {

    private let zurich = TimeZone(identifier: "Europe/Zurich")!  // UTC+2 in summer

    private func gapEvent(detail: String?) -> EventDTO {
        EventDTO(eventId: "evt_gap", at: "2026-09-01T06:31:45.416Z",
                 kind: "monitoring.gap", severity: "notice", deviceId: nil,
                 summary: "Monitoring was off between 2026-09-01T06:27:17.053Z "
                    + "and 2026-09-01T06:31:45.416Z.",
                 actor: "system", detail: detail)
    }

    func testSameDayGapFormatsLocalShortTimes() {
        let e = gapEvent(detail:
            #"{"v":1,"from":"2026-09-01T06:27:17.053Z","to":"2026-09-01T06:31:45.416Z"}"#)
        let text = GapVocabulary.displaySummary(e, timeZone: zurich)
        // Expected text is built through the SAME shared formatter (the space
        // before AM is the locale's narrow no-break space, not U+0020).
        let from = TimeFormatting.timeOnly("2026-09-01T06:27:17.053Z", timeZone: zurich)
        let to = TimeFormatting.timeOnly("2026-09-01T06:31:45.416Z", timeZone: zurich)
        XCTAssertEqual(text, "Monitoring was off between \(from) and \(to).")
        XCTAssertTrue(from.hasPrefix("8:27"), "local Zurich wall clock, got \(from)")
        XCTAssertFalse(text.contains("Z."), "no raw ISO stamps on screen")
    }

    func testCrossDayGapCarriesBothDates() {
        let e = gapEvent(detail:
            #"{"v":1,"from":"2026-08-31T21:18:05.440Z","to":"2026-09-01T06:27:17.053Z"}"#)
        let text = GapVocabulary.displaySummary(e, timeZone: zurich)
        XCTAssertTrue(text.contains("Aug 31, 2026"), "got: \(text)")
        XCTAssertTrue(text.contains("Sep 1, 2026"), "got: \(text)")
    }

    func testMissingDetailFallsBackToRawSummary() {
        let e = gapEvent(detail: nil)
        XCTAssertEqual(GapVocabulary.displaySummary(e, timeZone: zurich), e.summary)
    }

    func testUnparseableDetailFallsBackToRawSummary() {
        XCTAssertEqual(GapVocabulary.displaySummary(gapEvent(detail: "not json"), timeZone: zurich),
                       gapEvent(detail: nil).summary)
        XCTAssertEqual(GapVocabulary.displaySummary(
            gapEvent(detail: #"{"v":1,"from":"garbage","to":"alsogarbage"}"#), timeZone: zurich),
            gapEvent(detail: nil).summary)
    }

    // The popover's recent list renders gap rows through the same vocabulary.
    @MainActor
    func testPopoverRendersGapRowLocally() async {
        let fake = FakeAPIClient()
        fake.timelineResult = .success(TimelineDTO(events: [gapEvent(detail:
            #"{"v":1,"from":"2026-09-01T06:27:17.053Z","to":"2026-09-01T06:31:45.416Z"}"#)],
            nextCursor: nil))
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: zurich)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        let from = TimeFormatting.timeOnly("2026-09-01T06:27:17.053Z", timeZone: zurich)
        let to = TimeFormatting.timeOnly("2026-09-01T06:31:45.416Z", timeZone: zurich)
        XCTAssertEqual(c.events.first?.summary,
                       "Monitoring was off between \(from) and \(to).")
    }
}
