// PopoverViewModel.swift
//
// The popover (04): triage in three seconds. Active alerts first, then the last
// five events, then a one-line status footer. States: loading, empty, normal,
// degraded, stopped, store error, at-scale. The empty predicate is the SAME
// predicate as the list (data honesty): the empty sentence renders iff there is
// nothing to show. Alerts cap at three with "and N more"; events stay at five.

import Foundation

/// A one-line popover event row (the summary sentence the UI and MCP share).
public struct PopoverEventRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let summary: String
    public let severity: String
    public init(id: String, summary: String, severity: String) {
        self.id = id; self.summary = summary; self.severity = severity
    }
}

/// A one-line active-alert row; its only control is Details (04).
public struct PopoverAlertRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let summary: String
    public let severity: String
    public init(id: String, summary: String, severity: String) {
        self.id = id; self.summary = summary; self.severity = severity
    }
}

public enum PopoverFooter: Equatable, Sendable {
    case normal(String)
    /// Footer names the missing grant + carries a Grant link (1b/1e).
    case degraded(missingGrant: String)
}

/// The content body when the daemon is up and the store is readable.
public struct PopoverContent: Equatable, Sendable {
    public var alerts: [PopoverAlertRow]      // capped at 3
    public var moreAlertsCount: Int           // "and N more"
    public var events: [PopoverEventRow]      // up to 5
    public var footer: PopoverFooter

    /// Data-honesty predicate: empty iff BOTH lists are empty. This is the exact
    /// predicate the view uses to decide whether to render the empty sentence.
    public var isEmpty: Bool { alerts.isEmpty && events.isEmpty }

    /// The exact empty sentence (04). Non-nil iff `isEmpty`.
    public var emptySentence: String? {
        isEmpty ? "Monitoring. Nothing has plugged in yet." : nil
    }
}

public enum PopoverState: Equatable, Sendable {
    case loading
    case content(PopoverContent)
    case stopped(message: String)          // single message + Start monitoring
    case storeError(message: String)       // "Can't read the event record" + Reopen
}

@MainActor
public final class PopoverViewModel: ObservableObject {
    @Published public private(set) var state: PopoverState = .loading
    private let api: APIClient

    public init(api: APIClient) { self.api = api }

    /// Convenience for the snapshot generator and previews.
    public init(previewState: PopoverState) {
        self.api = FakeAPIClient()
        self.state = previewState
    }

    public func load() async {
        do {
            let status = try await api.getStatus()
            if status.monitoring == .stopped {
                state = .stopped(message: "Monitoring is stopped.")
                return
            }
            let alerts = try await api.listAlerts(state: "active", deviceId: nil, cursor: nil)
            let timeline = try await api.getTimeline(deviceId: nil, kinds: nil, severity: nil, cursor: nil)

            // Alerts cap at 3 with "and N more"; events stay at 5.
            let allAlerts = alerts.alerts
            let cappedAlerts = allAlerts.prefix(3).map {
                PopoverAlertRow(id: $0.alertId, summary: $0.summary, severity: $0.severity)
            }
            let more = max(0, allAlerts.count - cappedAlerts.count)
            let events = timeline.events.prefix(5).map {
                PopoverEventRow(id: $0.eventId, summary: $0.summary, severity: $0.severity)
            }

            let footer: PopoverFooter
            if status.monitoring == .degraded, let grant = GrantNaming.firstMissingGrant(status) {
                footer = .degraded(missingGrant: grant)
            } else {
                footer = .normal("Monitoring \(status.devicesPresent) device\(status.devicesPresent == 1 ? "" : "s").")
            }

            state = .content(PopoverContent(
                alerts: Array(cappedAlerts), moreAlertsCount: more,
                events: Array(events), footer: footer))
        } catch let e as APIError {
            switch e.kind {
            case .daemonUnreachable, .versionMismatch:
                state = .stopped(message: e.message)
            default:
                state = .storeError(message: e.message)
            }
        } catch {
            state = .storeError(message: "Can't read the event record")
        }
    }
}
