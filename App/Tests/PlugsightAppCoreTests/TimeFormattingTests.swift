import XCTest
@testable import PlugsightAppCore

/// The one shared wall-clock formatter (timezone honesty): ISO-8601 UTC wire
/// strings become LOCAL times via real parsing, never string slicing, and all
/// date text uses one fixed English locale so no mixed-language rows appear.
final class TimeFormattingTests: XCTestCase {

    private let plusTwo = TimeZone(secondsFromGMT: 2 * 3600)!

    // MARK: - parsing

    func testParsesFractionalAndPlainISO() {
        XCTAssertNotNil(TimeFormatting.parseISO("2026-08-25T09:14:02.123Z"))
        XCTAssertNotNil(TimeFormatting.parseISO("2026-08-25T09:14:02Z"))
        XCTAssertNil(TimeFormatting.parseISO("not a date"))
    }

    // MARK: - timeOnly

    func testTimeOnlyConvertsToTheGivenTimezone() {
        // 23:30 UTC is 01:30 the NEXT day at UTC+2 — string slicing would say 23:30.
        let s = TimeFormatting.timeOnly("2026-08-25T23:30:00Z", timeZone: plusTwo)
        XCTAssertTrue(s.contains("1:30"), "expected the local wall-clock 1:30, got '\(s)'")
        XCTAssertFalse(s.contains("23:30"), "must not echo the UTC time")
    }

    func testTimeOnlyFallsBackToInputWhenUnparseable() {
        XCTAssertEqual(TimeFormatting.timeOnly("garbage", timeZone: plusTwo), "garbage")
    }

    // MARK: - dateTime

    func testDateTimeIsLocalEnglishAndNeverRawISO() {
        let s = TimeFormatting.dateTime("2026-08-25T23:30:00Z", timeZone: plusTwo)
        XCTAssertTrue(s.contains("Aug 26"), "UTC+2 crosses midnight into Aug 26, got '\(s)'")
        XCTAssertTrue(s.contains("2026"))
        XCTAssertFalse(s.contains("T"), "no raw ISO markers in display text")
        XCTAssertFalse(s.contains("Z"), "no raw ISO markers in display text")
    }

    func testDateTimeFallsBackToInputWhenUnparseable() {
        XCTAssertEqual(TimeFormatting.dateTime("garbage"), "garbage")
    }

    // MARK: - day keys and labels

    func testDayKeyIsTheLocalDayNotTheUTCDay() {
        XCTAssertEqual(TimeFormatting.dayKey("2026-08-25T23:30:00Z", timeZone: plusTwo), "2026-08-26")
        XCTAssertEqual(TimeFormatting.dayKey("2026-08-25T09:14:02Z", timeZone: plusTwo), "2026-08-25")
        // Unparseable falls back to the ISO prefix rather than inventing a date.
        XCTAssertEqual(TimeFormatting.dayKey("garbage", timeZone: plusTwo), "garbage")
    }

    func testDayLabelTodayYesterdayAndFixedEnglishMedium() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = plusTwo
        let now = cal.date(from: DateComponents(timeZone: plusTwo, year: 2026, month: 8, day: 26, hour: 12))!
        XCTAssertEqual(TimeFormatting.dayLabel(forDayKey: "2026-08-26", now: now, timeZone: plusTwo), "Today")
        XCTAssertEqual(TimeFormatting.dayLabel(forDayKey: "2026-08-25", now: now, timeZone: plusTwo), "Yesterday")
        // Older days: fixed en_US medium date — English month word, no locale mixing.
        XCTAssertEqual(TimeFormatting.dayLabel(forDayKey: "2026-08-20", now: now, timeZone: plusTwo), "Aug 20, 2026")
        // Unparseable day keys fall back to themselves.
        XCTAssertEqual(TimeFormatting.dayLabel(forDayKey: "garbage", now: now, timeZone: plusTwo), "garbage")
    }
}
