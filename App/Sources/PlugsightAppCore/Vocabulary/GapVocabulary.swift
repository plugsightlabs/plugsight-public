// GapVocabulary.swift
//
// How a monitoring.gap event reads on screen. The daemon's stored summary
// embeds raw UTC ISO stamps ("Monitoring was off between 2026-09-01T06:27:17.053Z
// and ..."), which is machine truth, not human text. The event's structured
// detail carries the window as {"from","to"}; this vocabulary formats it with
// the shared TimeFormatting (viewer's local timezone, short style) and falls
// back to the raw summary only when the detail is missing or unparseable
// (honest raw data beats an invented time).

import Foundation

public enum GapVocabulary {

    /// "Monitoring was off between 8:27 AM and 8:31 AM." from the structured
    /// detail; when the window spans local days, both ends carry their date.
    /// nil when the detail has no parseable from/to.
    public static func sentence(detail: String?, timeZone: TimeZone = .current) -> String? {
        guard let detail,
              let data = detail.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let from = obj["from"] as? String,
              let to = obj["to"] as? String,
              TimeFormatting.parseISO(from) != nil,
              TimeFormatting.parseISO(to) != nil else { return nil }
        let sameLocalDay = TimeFormatting.dayKey(from, timeZone: timeZone)
            == TimeFormatting.dayKey(to, timeZone: timeZone)
        let fromText = sameLocalDay
            ? TimeFormatting.timeOnly(from, timeZone: timeZone)
            : TimeFormatting.dateTime(from, timeZone: timeZone)
        let toText = sameLocalDay
            ? TimeFormatting.timeOnly(to, timeZone: timeZone)
            : TimeFormatting.dateTime(to, timeZone: timeZone)
        return "Monitoring was off between \(fromText) and \(toText)."
    }

    /// What a gap row shows: the local-time sentence, or the raw summary when
    /// the event carries no usable detail (an older daemon, or hand-seeded data).
    public static func displaySummary(_ event: EventDTO, timeZone: TimeZone = .current) -> String {
        sentence(detail: event.detail, timeZone: timeZone) ?? event.summary
    }
}
