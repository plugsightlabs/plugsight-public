// TimelineViewModel.swift
//
// The Activity view's model (04, S10): the readable forensic record, reached
// from the Devices home link. ONE real filter — Alerts only — which reads the
// active alerts instead of the raw event stream. Empty states split by that
// predicate (data honesty). Store-error carries what/why/Reopen. At-scale it
// groups by day and renders monitoring-gap rows inline so absence of data is
// data (7a).

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
    /// True when the rows are the ACTIVE ALERTS view (the one real filter).
    public var alertsOnly: Bool = false

    /// The empty sentence, split by the filter predicate (04, data honesty).
    /// The alerts-only empty is good news, and it SAYS the filter is on so an
    /// empty list is never mistaken for an empty history; the view pairs it
    /// with an inline "Show everything" action.
    public var emptySentence: String? {
        guard isEmpty else { return nil }
        if alertsOnly { return "No active alerts. The Alerts only filter is on." }
        return filtersActive
            ? "No events match these filters"
            : "No events yet. Plug something in and it will appear here."
    }
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
    /// place. Pure so the at-scale grouping is unit-testable. Days are the
    /// VIEWER'S local calendar days (timezone honesty): an event at 23:30Z is
    /// grouped under the next local day east of UTC, matching the local times
    /// the rows display.
    public static func rows(from timeline: TimelineDTO, now: Date = Date(),
                            timeZone: TimeZone = .current) -> [TimelineRow] {
        // Events newest first (the daemon already returns them so), with day
        // headers spliced in on each day change. A `monitoring.gap` event renders
        // as an explicit gap row rather than an ordinary event (06/7a).
        let events = timeline.events.sorted { $0.at > $1.at }
        var rows: [TimelineRow] = []
        var currentDay: String?
        for e in events {
            let day = TimeFormatting.dayKey(e.at, timeZone: timeZone)
            if day != currentDay {
                // Humanize the header (Today / Yesterday / fixed-English medium
                // date); the day key is kept only for change detection, never shown.
                rows.append(.dayHeader(TimeFormatting.dayLabel(forDayKey: day, now: now, timeZone: timeZone)))
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

    /// Humanize a local day key ("2026-08-25") into "Today", "Yesterday", or a
    /// fixed-English medium date ("Aug 25, 2026"). Thin wrapper over the shared
    /// formatter (TimeFormatting), kept for callers/tests that speak day keys.
    public static func dayHeaderLabel(forISODay day: String,
                                      now: Date = Date(),
                                      timeZone: TimeZone = .current) -> String {
        TimeFormatting.dayLabel(forDayKey: day, now: now, timeZone: timeZone)
    }

    /// The alerts-only face: each active alert rendered as a timeline row (day
    /// grouping and local times identical to the event rows). Pure for tests.
    public static func timeline(fromAlerts alerts: AlertListDTO) -> TimelineDTO {
        TimelineDTO(events: alerts.alerts.map { a in
            EventDTO(eventId: a.alertId, at: a.at, kind: "alert",
                     severity: a.severity, deviceId: a.deviceId,
                     summary: a.summary, actor: "system")
        }, nextCursor: alerts.nextCursor)
    }

    /// `now` is injectable so deterministic renders (the snapshot gate) can pin
    /// the day-header humanizer to the canned event day rather than the live
    /// clock; it defaults to the live clock for the running app.
    public func load(now: Date = Date()) async {
        do {
            // The one real filter (04): Alerts only reads the ACTIVE alerts
            // (alerts.list) instead of the raw event stream — an honest filter,
            // not a decorated one.
            let timeline: TimelineDTO
            if filters.activeAlertsOnly {
                timeline = Self.timeline(fromAlerts: try await api.listAlerts(
                    state: "active", deviceId: filters.deviceId, cursor: nil))
            } else {
                timeline = try await api.getTimeline(
                    deviceId: filters.deviceId, kinds: filters.kind.map { [$0] },
                    severity: filters.severity, cursor: nil)
            }
            let loaded = TimelineLoaded(
                rows: Self.rows(from: timeline, now: now),
                hasMore: timeline.nextCursor != nil,
                isEmpty: timeline.events.isEmpty,
                filtersActive: filters.isActive,
                alertsOnly: filters.activeAlertsOnly)
            state = .loaded(loaded)
        } catch let e as APIError {
            state = .storeError(message: e.message)
        } catch {
            state = .storeError(message: "Can't read the event record")
        }
    }
}
