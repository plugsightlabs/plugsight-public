// TimeFormatting.swift
//
// The ONE place wire timestamps become wall-clock text (timezone honesty).
// The daemon speaks ISO-8601 UTC; every surface that shows a time parses it
// here and renders it in the viewer's LOCAL timezone. Rules:
//
//   - Never string-slice an ISO string for display. Parse, then format.
//   - All date TEXT uses one fixed English locale (the app is English-only),
//     so "Today" never sits next to a German month name.
//   - An unparseable input falls back to itself: honest raw data beats an
//     invented date.
//
// View models call these with the default `.current` timezone; tests inject an
// explicit one for determinism.

import Foundation

public enum TimeFormatting {

    /// The fixed display locale: the app's copy is English-only, so date text
    /// is too (no mixed-language rows).
    public static let displayLocale = Locale(identifier: "en_US")

    // MARK: - Parsing (wire -> Date)

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse a daemon ISO-8601 timestamp (with or without fractional seconds).
    public static func parseISO(_ iso: String) -> Date? {
        isoFractional.date(from: iso) ?? isoPlain.date(from: iso)
    }

    // MARK: - Display (Date -> local text)

    /// Short local time, e.g. "9:14 AM". Falls back to the input when it does
    /// not parse.
    public static func timeOnly(_ iso: String, timeZone: TimeZone = .current) -> String {
        guard let date = parseISO(iso) else { return iso }
        let f = DateFormatter()
        f.locale = displayLocale
        f.timeZone = timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Medium local date + short local time, e.g. "Aug 26, 2026 at 1:30 AM".
    /// Falls back to the input when it does not parse.
    public static func dateTime(_ iso: String, timeZone: TimeZone = .current) -> String {
        guard let date = parseISO(iso) else { return iso }
        let f = DateFormatter()
        f.locale = displayLocale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Day grouping (local calendar days)

    private static func dayKeyFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// The LOCAL calendar day ("2026-08-26") an ISO timestamp falls on — a
    /// grouping key, never shown. An unparseable input falls back to its ISO
    /// date prefix so grouping still works.
    public static func dayKey(_ iso: String, timeZone: TimeZone = .current) -> String {
        guard let date = parseISO(iso) else { return String(iso.prefix(10)) }
        return dayKeyFormatter(timeZone).string(from: date)
    }

    /// Humanize a local day key: "Today", "Yesterday" (English, app language),
    /// else a fixed-locale medium date ("Aug 20, 2026"). Falls back to the key
    /// itself when it does not parse.
    public static func dayLabel(forDayKey day: String, now: Date = Date(),
                                timeZone: TimeZone = .current) -> String {
        let key = dayKeyFormatter(timeZone)
        guard let date = key.date(from: day) else { return day }
        if day == key.string(from: now) { return "Today" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           day == key.string(from: yesterday) { return "Yesterday" }
        let medium = DateFormatter()
        medium.locale = displayLocale
        medium.timeZone = timeZone
        medium.dateStyle = .medium
        medium.timeStyle = .none
        return medium.string(from: date)
    }
}
