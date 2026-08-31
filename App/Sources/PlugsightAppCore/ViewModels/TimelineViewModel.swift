// TimelineViewModel.swift
//
// The Timeline section (04): the readable forensic record, filterable. Two empty
// states split by the filter predicate (data honesty): "no events yet" when no
// filters are active, "no events match these filters" + Clear filters when they
// are. Store-error carries what/why/Reopen. At-scale it groups by day and renders
// monitoring-gap rows inline so absence of data is data (7a).

import Foundation

/// The active filter set. `isActive` is the predicate that decides WHICH empty
/// state renders — the same predicate the chips reflect.
public struct TimelineFilters: Equatable, Sendable {
    public var deviceId: String?
    public var severity: String?
    public var kind: String?
    public var activeAlertsOnly: Bool
    public init(deviceId: String? = nil, severity: String? = nil, kind: String? = nil, activeAlertsOnly: Bool = false) {
        self.deviceId = deviceId; self.severity = severity; self.kind = kind; self.activeAlertsOnly = activeAlertsOnly
    }
    public var isActive: Bool {
        deviceId != nil || severity != nil || kind != nil || activeAlertsOnly
    }
}

/// One rendered timeline row: an event, an explicit monitoring-gap row (rendered
/// from a `monitoring.gap` EVENT, 06), or a day header.
public enum TimelineRow: Equatable, Sendable, Identifiable {
    case event(EventDTO)
    /// A monitoring gap, carried as its event so the readable "Monitoring was off
    /// between…" summary renders directly (the window lives in the summary; the
    /// timeline event shape carries no separate from/to).
    case gap(EventDTO)
    case dayHeader(String)

    public var id: String {
        switch self {
        case .event(let e): return "e:\(e.eventId)"
        case .gap(let e): return "g:\(e.eventId)"
        case .dayHeader(let d): return "h:\(d)"
        }
    }
}

public struct TimelineLoaded: Equatable, Sendable {
    public var rows: [TimelineRow]
    public var hasMore: Bool
    /// True iff there are zero EVENTS (gaps/headers don't count as data).
    public var isEmpty: Bool
    public var filtersActive: Bool

    /// The empty sentence, split by the filter predicate (04, data honesty).
    public var emptySentence: String? {
        guard isEmpty else { return nil }
        return filtersActive
            ? "No events match these filters"
            : "No events yet. Plug something in and it will appear here."
    }
    /// The empty state offers Clear filters only when filters are active.
    public var showsClearFilters: Bool { isEmpty && filtersActive }
}

public enum TimelineState: Equatable, Sendable {
    case loading
    case loaded(TimelineLoaded)
    case storeError(message: String)
}

@MainActor
public final class TimelineViewModel: ObservableObject {
    @Published public private(set) var state: TimelineState = .loading
    @Published public var filters = TimelineFilters()
    private let api: APIClient

    public init(api: APIClient) { self.api = api }
    public init(previewState: TimelineState, filters: TimelineFilters = .init()) {
        self.api = FakeAPIClient(); self.state = previewState; self.filters = filters
    }

    /// Group events into day-headed rows and splice gap rows in chronological
    /// place. Pure so the at-scale grouping is unit-testable.
    public static func rows(from timeline: TimelineDTO, now: Date = Date()) -> [TimelineRow] {
        // Events newest first (the daemon already returns them so), with day
        // headers spliced in on each day change. A `monitoring.gap` event renders
        // as an explicit gap row rather than an ordinary event (06/7a).
        let events = timeline.events.sorted { $0.at > $1.at }
        var rows: [TimelineRow] = []
        var currentDay: String?
        for e in events {
            let day = String(e.at.prefix(10))  // "2026-08-25"
            if day != currentDay {
                // Humanize the header (Today / Yesterday / medium date); the raw
                // ISO day is kept only for change detection, never shown.
                rows.append(.dayHeader(dayHeaderLabel(forISODay: day, now: now)))
                currentDay = day
            }
            if e.kind == "monitoring.gap" {
                rows.append(.gap(e))
            } else {
                rows.append(.event(e))
            }
        }
        return rows
    }

    /// Humanize an ISO day ("2026-08-25") into "Today", "Yesterday", or a locale
    /// medium date ("Aug 25, 2026"). Event days are UTC (the `Z` timestamps), so
    /// "today"/"yesterday" are computed in UTC to match; an unparseable value
    /// falls back to itself rather than inventing a date.
    public static func dayHeaderLabel(forISODay day: String,
                                      now: Date = Date(),
                                      locale: Locale = .current) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let iso = DateFormatter()
        iso.calendar = utc
        iso.timeZone = utc.timeZone
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"
        guard let date = iso.date(from: day) else { return day }
        let todayStr = iso.string(from: now)
        if day == todayStr { return "Today" }
        if let yesterday = utc.date(byAdding: .day, value: -1, to: now),
           day == iso.string(from: yesterday) { return "Yesterday" }
        let medium = DateFormatter()
        medium.calendar = utc
        medium.timeZone = utc.timeZone
        medium.locale = locale
        medium.dateStyle = .medium
        medium.timeStyle = .none
        return medium.string(from: date)
    }

    /// `now` is injectable so deterministic renders (the snapshot gate) can pin
    /// the day-header humanizer to the canned event day rather than the live
    /// clock; it defaults to the live clock for the running app.
    public func load(now: Date = Date()) async {
        do {
            let timeline = try await api.getTimeline(
                deviceId: filters.deviceId, kinds: filters.kind.map { [$0] },
                severity: filters.severity, cursor: nil)
            let loaded = TimelineLoaded(
                rows: Self.rows(from: timeline, now: now),
                hasMore: timeline.nextCursor != nil,
                isEmpty: timeline.events.isEmpty,
                filtersActive: filters.isActive)
            state = .loaded(loaded)
        } catch let e as APIError {
            state = .storeError(message: e.message)
        } catch {
            state = .storeError(message: "Can't read the event record")
        }
    }
}
