// PopoverViewModel.swift
//
// The popover (04): triage in three seconds. A machine verdict line first, then
// active alerts, then the last five events with local times, then a one-line
// status footer. States: loading, empty, normal, degraded, stopped, store error,
// at-scale. The empty predicate is the SAME predicate as the list (data
// honesty): the empty sentence renders iff there is nothing to show. Alerts cap
// at three with "and N more"; events stay at five.

import Foundation

/// A one-line popover event row: local time + the shared summary sentence.
public struct PopoverEventRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let summary: String
    public let severity: String
    /// The event's LOCAL wall-clock time (via TimeFormatting), e.g. "9:14 AM".
    public let time: String
    public init(id: String, summary: String, severity: String, time: String) {
        self.id = id; self.summary = summary; self.severity = severity; self.time = time
    }
}

/// A one-line active-alert row; its only control is Details (04), which routes
/// to the alert's device in the main window (hence `deviceId`).
public struct PopoverAlertRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let summary: String
    public let severity: String
    /// The alert's LOCAL wall-clock time, e.g. "9:14 AM".
    public let time: String
    /// Routes Details to the device inspector; nil falls back to the main window.
    public let deviceId: String?
    public init(id: String, summary: String, severity: String, time: String, deviceId: String?) {
        self.id = id; self.summary = summary; self.severity = severity
        self.time = time; self.deviceId = deviceId
    }
}

public enum PopoverFooter: Equatable, Sendable {
    case normal(String)
    /// Footer names the missing grant + carries a Grant link (1b/1e).
    case degraded(missingGrant: String)
}

/// The machine verdict line (04): one answer to "am I okay right now?".
public enum PopoverVerdict: Equatable, Sendable {
    case allSafe
    case needsAttention(count: Int)

    /// The plain verdict words the popover shows next to the verdict icon.
    public var word: String {
        switch self {
        case .allSafe: return "All devices safe"
        case .needsAttention(let n): return n == 1 ? "1 needs attention" : "\(n) need attention"
        }
    }

    /// The wire safety status whose icon + tint the verdict borrows (SafetyBadge).
    public var safetyStatus: String {
        switch self {
        case .allSafe: return "green"
        case .needsAttention: return "yellow"
        }
    }
}

/// The content body when the daemon is up and the store is readable.
public struct PopoverContent: Equatable, Sendable {
    public var verdict: PopoverVerdict
    public var alerts: [PopoverAlertRow]      // capped at 3
    public var moreAlertsCount: Int           // "and N more"
    public var events: [PopoverEventRow]      // up to 5
    public var footer: PopoverFooter
    /// Whether ANY device is on record (device list non-empty). Splits the
    /// empty sentence honestly: "nothing has plugged in yet" may only be
    /// claimed when the device record is empty too — never under a footer
    /// counting monitored devices.
    public var devicesKnown: Bool = false

    /// Data-honesty predicate: empty iff BOTH lists are empty. This is the exact
    /// predicate the view uses to decide whether to render the empty sentence.
    public var isEmpty: Bool { alerts.isEmpty && events.isEmpty }

    /// The exact empty sentence (04), split by what the device record says.
    /// Non-nil iff `isEmpty`.
    public var emptySentence: String? {
        guard isEmpty else { return nil }
        return devicesKnown
            ? "Nothing is connected right now."
            : "Monitoring. Nothing has plugged in yet."
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
    /// The stopped-state title line. Truthful: Plugsight (the app showing this
    /// text) IS running; what is off is monitoring (the daemon). The old copy
    /// said "Plugsight isn't running. Start Plugsight from your Applications
    /// folder" while Plugsight itself displayed the message.
    public static let stoppedTitle = "Monitoring is off."
    /// The supporting line under the title; the recovery is the Start
    /// monitoring button right beside it.
    public static let stoppedSupport = "Turn it on and Plugsight starts watching new devices."

    @Published public private(set) var state: PopoverState = .loading
    /// Honest post-update advisory (set by the shell when a start attempt left
    /// the daemon unreachable, e.g. a launch-constraint kill after the app
    /// bundle was replaced). When set, it replaces the stopped supporting line.
    @Published public var startAdvisory: String?
    private let api: APIClient
    /// Whether this build ships the .systemextension (the same guard onboarding
    /// uses). When it does not, the degraded footer never blames the extension:
    /// it is not installable, so nagging would be dishonest.
    private let extensionBundled: Bool

    public init(api: APIClient, extensionBundled: Bool = true) {
        self.api = api
        self.extensionBundled = extensionBundled
    }

    /// Convenience for the snapshot generator and previews.
    public init(previewState: PopoverState) {
        self.api = FakeAPIClient()
        self.extensionBundled = true
        self.state = previewState
    }

    public func load(timeZone: TimeZone = .current) async {
        do {
            let status = try await api.getStatus()
            if status.monitoring == .stopped {
                state = .stopped(message: startAdvisory ?? Self.stoppedSupport)
                return
            }
            let alerts = try await api.listAlerts(state: "active", deviceId: nil, cursor: nil)
            let timeline = try await api.getTimeline(deviceId: nil, kinds: nil, severity: nil, cursor: nil)

            // Alerts cap at 3 with "and N more"; events stay at 5.
            let allAlerts = alerts.alerts
            let cappedAlerts = allAlerts.prefix(3).map {
                PopoverAlertRow(id: $0.alertId, summary: $0.summary, severity: $0.severity,
                                time: TimeFormatting.timeOnly($0.at, timeZone: timeZone),
                                deviceId: $0.deviceId)
            }
            let more = max(0, allAlerts.count - cappedAlerts.count)
            let events = timeline.events.prefix(5).map { (e: EventDTO) -> PopoverEventRow in
                // Gap rows read as local wall-clock text, never raw UTC ISO.
                let summary = e.kind == "monitoring.gap"
                    ? GapVocabulary.displaySummary(e, timeZone: timeZone)
                    : e.summary
                return PopoverEventRow(id: e.eventId, summary: summary, severity: e.severity,
                                       time: TimeFormatting.timeOnly(e.at, timeZone: timeZone))
            }

            // The verdict counts DEVICES needing attention (distinct devices with
            // an active alert; a device-less alert counts once on its own).
            let verdict: PopoverVerdict
            if allAlerts.isEmpty {
                verdict = .allSafe
            } else {
                let deviceIds = Set(allAlerts.compactMap(\.deviceId))
                let deviceless = allAlerts.filter { $0.deviceId == nil }.count
                verdict = .needsAttention(count: deviceIds.count + deviceless)
            }

            let footer: PopoverFooter
            if status.monitoring == .degraded,
               let grant = GrantNaming.firstMissingGrant(status, extensionBundled: extensionBundled) {
                footer = .degraded(missingGrant: grant)
            } else {
                footer = .normal("Monitoring \(status.devicesPresent) device\(status.devicesPresent == 1 ? "" : "s").")
            }

            // Only when the popover would render its empty state does the split
            // predicate matter: ask the device record whether anything was EVER
            // seen, so the sentence never contradicts the footer's device count.
            var devicesKnown = status.devicesPresent > 0
            if allAlerts.isEmpty && events.isEmpty && !devicesKnown {
                let known = try? await api.listDevices(present: nil, trust: nil, cursor: nil)
                devicesKnown = known.map { !$0.devices.isEmpty } ?? false
            }

            state = .content(PopoverContent(
                verdict: verdict,
                alerts: Array(cappedAlerts), moreAlertsCount: more,
                events: Array(events), footer: footer,
                devicesKnown: devicesKnown))
        } catch let e as APIError {
            switch e.kind {
            case .daemonUnreachable:
                // Truthful stopped copy: the daemon is off, not the app the
                // user is looking at. The wire message ("start Plugsight from
                // your Applications folder") lies in this surface.
                state = .stopped(message: startAdvisory ?? Self.stoppedSupport)
            case .versionMismatch:
                state = .stopped(message: e.message)
            default:
                state = .storeError(message: e.message)
            }
        } catch {
            state = .storeError(message: "Can't read the event record")
        }
    }
}
