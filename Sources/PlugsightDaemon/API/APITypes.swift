// APITypes.swift
//
// FROZEN CONTRACT for the local API (docs/spec/02 "The local API"). These
// Codable request-params and result DTOs are the wire shapes consumed by the
// menu-bar app (N9) and the MCP server (N10). Transcribed from 02's method table
// and 03's documented JSON shapes. Field names are camelCase on the wire.
//
// Do not rename or retype a field here without bumping `apiVersion` — downstream
// nodes decode exactly these shapes.

import Foundation
import PlugsightCore

// MARK: - auth.hello

public struct ClientInfo: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String   // "ui" | "mcp" | "cli"
    public init(name: String, kind: String) { self.name = name; self.kind = kind }
}

public struct HelloParams: Codable, Sendable {
    public var token: String
    public var clientInfo: ClientInfo
}

/// Degraded-mode capability flags (02: "capabilities reports degraded modes
/// (no Input Monitoring, no ES, no ClamAV) as booleans"). True == capability
/// present/active.
public struct Capabilities: Codable, Sendable, Equatable {
    public var inputMonitoring: Bool
    public var endpointSecurity: Bool
    public var clamav: Bool
    public init(inputMonitoring: Bool, endpointSecurity: Bool, clamav: Bool) {
        self.inputMonitoring = inputMonitoring
        self.endpointSecurity = endpointSecurity
        self.clamav = clamav
    }
}

public struct HelloResult: Codable, Sendable {
    public var apiVersion: Int
    public var daemonVersion: String
    public var capabilities: Capabilities
}

// MARK: - status.get

public struct Permissions: Codable, Sendable {
    /// The Input Monitoring PERMISSION, re-checked fresh on every status.get
    /// (a grant made while the daemon runs registers without a restart).
    public var inputMonitoring: Bool
    /// Whether the typing-rhythm SENSOR is actually collecting:
    /// "active" (opened at boot) | "restart_required" (permission granted, but
    /// the HID sensor only opens at daemon start) | "off" (not granted).
    /// Optional so older clients that never look for it decode unchanged.
    public var inputMonitoringSensor: String?
    public var esExtension: String   // "active" | "inactive" | "not_installed"
}

public struct ScannerStatus: Codable, Sendable {
    public var available: Bool
    public var engine: String?
    public var definitionsAgeDays: Int?
    /// One-click ClamAV install progress (onboarding scanner step): one of
    /// "idle" | "installing" | "failed" | "done".
    public var installState: String
    /// The latest human-readable progress line, or the error tail on failure;
    /// nil when idle.
    public var installDetail: String?

    public init(available: Bool, engine: String?, definitionsAgeDays: Int?,
                installState: String = "idle", installDetail: String? = nil) {
        self.available = available
        self.engine = engine
        self.definitionsAgeDays = definitionsAgeDays
        self.installState = installState
        self.installDetail = installDetail
    }
}

// MARK: - scanner.install

/// Result of `scanner.install` (app<->daemon RPC only; NOT an MCP tool). The app
/// polls status.get's installState/installDetail for progress after this returns.
public struct ScannerInstallResult: Codable, Sendable {
    /// true when an install was started; false when it cannot start (an install
    /// is already running, or Homebrew is not found).
    public var accepted: Bool
    /// The human-readable reason when `accepted` is false; nil on success.
    public var reason: String?

    public init(accepted: Bool, reason: String?) {
        self.accepted = accepted
        self.reason = reason
    }
}

public struct MonitoringGap: Codable, Sendable {
    public var from: String
    public var to: String
}

public struct StatusResult: Codable, Sendable {
    public var monitoring: String   // "active" | "degraded" | "stopped"
    public var daemonVersion: String
    public var uptimeSeconds: Int
    public var permissions: Permissions
    public var scanner: ScannerStatus
    public var devicesPresent: Int
    public var activeAlerts: Int
    public var eventCount: Int
    public var monitoringGaps: [MonitoringGap]
}

// MARK: - devices.list / devices.get

public struct DevicesFilter: Codable, Sendable {
    public var present: Bool?
    public var trust: String?
    public var deviceClass: String?
    enum CodingKeys: String, CodingKey {
        case present, trust
        case deviceClass = "class"
    }
}

public struct DevicesListParams: Codable, Sendable {
    public var filter: DevicesFilter?
    public var limit: Int?
    public var cursor: String?
}

public struct ScoreBrief: Codable, Sendable {
    public var value: Int
    public var confidence: String
}

/// The most recent scan for a device, briefly (device-summary truthfulness):
/// state word + finish time, so a device row can say "Scanning..." or "last
/// scan clean" without a scans.list round trip.
public struct LastScanBrief: Codable, Sendable {
    public var scanId: String
    public var state: String
    public var finishedAt: String?
    public init(scanId: String, state: String, finishedAt: String?) {
        self.scanId = scanId; self.state = state; self.finishedAt = finishedAt
    }
}

public struct DeviceSummary: Codable, Sendable {
    public var deviceId: String
    public var name: String
    public var present: Bool
    public var firstSeen: String
    public var lastSeen: String
    public var vidPid: String
    public var serial: String?
    public var interfaceClasses: [String]
    public var trust: String
    public var score: ScoreBrief?
    public var activeAlerts: Int
    /// True while a scan of this device is in flight (drives "Scanning...").
    public var scanning: Bool
    /// The most recent scan, nil when the device was never scanned.
    public var lastScan: LastScanBrief?
    /// The derived verdict (04 verdict model): status word + plain-language
    /// reasons, each with one recommended action. Identical on devices.get and
    /// over MCP; the wire shape is PlugsightCore.SafetyStatus.
    public var safetyStatus: SafetyStatus
}

public struct DevicesListResult: Codable, Sendable {
    public var devices: [DeviceSummary]
    public var nextCursor: String?
}

public struct DeviceGetParams: Codable, Sendable {
    public var deviceId: String
}

/// Interface row: the raw USB codes PLUS the plain-language role (03/06). Wire
/// keys are the raw codewords `class`/`subclass`/`protocol` (matching the UI DTO
/// and 03) — NOT the Swift property names.
public struct InterfaceDTO: Codable, Sendable {
    public var seq: Int
    public var usbClass: Int
    public var usbSubclass: Int
    public var usbProtocol: Int
    public var role: String
    enum CodingKeys: String, CodingKey {
        case seq
        case usbClass = "class"
        case usbSubclass = "subclass"
        case usbProtocol = "protocol"
        case role
    }
    public init(seq: Int, usbClass: Int, usbSubclass: Int, usbProtocol: Int, role: String) {
        self.seq = seq; self.usbClass = usbClass; self.usbSubclass = usbSubclass
        self.usbProtocol = usbProtocol; self.role = role
    }
}

/// One trust-history entry (03: "trust history with actors"). Derived from the
/// device's `trust.changed` events — the tier it moved TO, who did it, when, and
/// the note if any. 06: trust history is not a table, it is an event query.
public struct TrustHistoryEntry: Codable, Sendable {
    public var tier: String
    public var actor: String
    public var at: String
    public var note: String?
    public init(tier: String, actor: String, at: String, note: String?) {
        self.tier = tier; self.actor = actor; self.at = at; self.note = note
    }
}

/// Device topology (03: "topology (port and hub path)"). Derived from the port
/// path the collector recorded on the device's most recent `device.attached`
/// event; nil when unknown (e.g. a historical device seen before we recorded it).
public struct TopologyDTO: Codable, Sendable {
    /// The full bus/port string, e.g. "20-2.4".
    public var port: String
    /// The hub hops parsed from the port string, e.g. ["2","4"].
    public var hubPath: [String]
    public init(port: String, hubPath: [String]) { self.port = port; self.hubPath = hubPath }
}

/// Full device record (devices.get). Carries the per-interface raw codes + role,
/// trust history (with actors), topology (port/hub path), and the derived
/// `isStorage` flag the inspector uses to offer Eject.
public struct DeviceRecord: Codable, Sendable {
    public var deviceId: String
    public var name: String
    public var present: Bool
    public var firstSeen: String
    public var lastSeen: String
    public var vidPid: String
    public var serial: String?
    public var identityBasis: String
    public var trust: String
    public var trustNote: String?
    public var trustSetBy: String?
    public var trustSetAt: String?
    public var interfaces: [InterfaceDTO]
    public var score: ScoreBrief?
    public var eventCount: Int
    public var scanCount: Int
    public var trustHistory: [TrustHistoryEntry]
    public var topology: TopologyDTO?
    public var isStorage: Bool
    /// True while a scan of this device is in flight (same truth as the
    /// summary's flag, so devices.get tells the same story as devices.list).
    public var scanning: Bool
    /// The most recent scan, nil when the device was never scanned.
    public var lastScan: LastScanBrief?
    /// The derived verdict (04 verdict model), same derivation as the summary.
    public var safetyStatus: SafetyStatus
}

// MARK: - timeline.list / events.get / events.tail

public struct TimelineFilter: Codable, Sendable {
    public var deviceId: String?
    public var kinds: [String]?
    public var severity: String?
    public var since: String?
    public var until: String?
}

public struct TimelineListParams: Codable, Sendable {
    public var filter: TimelineFilter?
    public var limit: Int?
    public var cursor: String?
}

public struct TimelineEvent: Codable, Sendable {
    public var eventId: String
    public var at: String
    public var kind: String
    public var severity: String
    public var deviceId: String?
    public var summary: String
    public var actor: String
    /// The event's structured detail as its raw stored JSON string (additive;
    /// omitted when empty). Lets renderers use the machine facts — e.g. the
    /// monitoring.gap from/to window formatted in the viewer's timezone —
    /// instead of re-parsing the human summary.
    public var detail: String? = nil
}

public struct TimelineListResult: Codable, Sendable {
    public var events: [TimelineEvent]
    public var nextCursor: String?
}

public struct EventGetParams: Codable, Sendable {
    public var eventId: String
}

/// A next action an explanation/alert names, each pointing at the tool that
/// performs it (03: "no dead ends" — every explanation names a next action).
public struct SuggestedAction: Codable, Sendable, Equatable {
    public var tool: String
    public var label: String
    public init(tool: String, label: String) { self.tool = tool; self.label = label }
}

/// The context object an explanation carries (03: "context (device, trust state
/// at the time, related events)"). Also carries the event's raw `detail` payload.
public struct EventContext: Codable, Sendable {
    public var detail: JSONValue
    public var deviceId: String?
    public var deviceName: String?
    public var trust: String?
    public var alertId: String?
}

/// events.get / explain_event result (03): the event, `why` (the rule/signal
/// that produced it), `context`, and `suggestedActions` (each naming its tool).
public struct EventDetailResult: Codable, Sendable {
    public var event: TimelineEvent
    public var why: String
    public var context: EventContext
    public var suggestedActions: [SuggestedAction]
}

public struct EventsTailParams: Codable, Sendable {
    public var filter: TimelineFilter?
}

public struct EventsTailResult: Codable, Sendable {
    public var subscriptionId: String
}

public struct EventsUntailParams: Codable, Sendable {
    public var subscriptionId: String
}

public struct EventsUntailResult: Codable, Sendable {
    public var ok: Bool
}

// MARK: - score.get

public struct ScoreSignal: Codable, Sendable {
    public var id: String
    public var observed: String
    public var verdict: String
    public var weight: Double
}

/// score.get result. Null-not-zero (04 4b/4c): `score` is null (never 0) when the
/// sensor is off OR nothing was observed, and `sensorAvailable` reports whether
/// Input Monitoring is granted so the UI can say "sensor off" rather than "no
/// number". The caveat rides on every payload (charter/03).
public struct ScoreResult: Codable, Sendable {
    public var score: Int?
    public var confidence: String?
    public var signals: [ScoreSignal]
    public var explanation: String
    public var caveat: String
    public var sensorAvailable: Bool
}

public struct ScoreGetParams: Codable, Sendable {
    public var deviceId: String
}

// MARK: - alerts.list / alerts.ack

public struct AlertsFilter: Codable, Sendable {
    public var state: String?
    public var severity: String?
    public var deviceId: String?
}

public struct AlertsListParams: Codable, Sendable {
    public var filter: AlertsFilter?
    public var limit: Int?
    public var cursor: String?
}

/// One alert (alerts.list / alerts.ack). Carries the resolved `deviceName`, the
/// `at` timestamp, and `suggestedActions` the UI/agent renders (03: same
/// summary/why/suggestedActions shape as explain_event). The ack bookkeeping
/// fields ride alongside for callers that want them.
public struct AlertDTO: Codable, Sendable {
    public var alertId: String
    public var deviceId: String?
    public var deviceName: String
    public var rule: String
    public var severity: String
    public var state: String
    public var at: String
    public var raisedAt: String
    public var updatedAt: String
    public var summary: String
    public var why: String
    public var suggestedActions: [SuggestedAction]
    public var ackedBy: String?
    public var ackedAt: String?
    public var ackComment: String?
}

public struct AlertsListResult: Codable, Sendable {
    public var alerts: [AlertDTO]
    public var nextCursor: String?
}

public struct AlertsAckParams: Codable, Sendable {
    public var alertId: String
    public var comment: String?
}

/// Write tools return the updated object plus the timeline event they appended
/// (03 "Write tools"), so a client can quote exactly what changed.
public struct AlertsAckResult: Codable, Sendable {
    public var alert: AlertDTO
    public var event: TimelineEvent
}

// MARK: - trust.set

public struct TrustSetParams: Codable, Sendable {
    public var deviceId: String
    public var tier: String        // trusted | muted | flagged | none
    public var note: String?
}

public struct TrustSetResult: Codable, Sendable {
    public var device: DeviceRecord
    public var event: TimelineEvent
    /// Charter item 4: trust decisions are forgeable; the caveat rides on every
    /// trust mutation.
    public var caveat: String
}

// MARK: - scans

public struct ScanStartParams: Codable, Sendable {
    public var deviceId: String?
    public var volumePath: String?
}

public struct ScanStartResult: Codable, Sendable {
    public var scanId: String
    public var state: String
}

public struct ScanGetParams: Codable, Sendable {
    public var scanId: String
}

/// One per-file verdict (03: "per-file verdicts"). The daemon records detections
/// as scan_findings, so a verdict is emitted per finding with verdict "infected".
public struct ScanVerdictDTO: Codable, Sendable {
    public var filePath: String
    public var verdict: String        // "infected" (clean files are not recorded)
    public var signature: String?
    public init(filePath: String, verdict: String, signature: String?) {
        self.filePath = filePath; self.verdict = verdict; self.signature = signature
    }
}

/// One quarantine record within a scan (03: "quarantine records"). `quarantineId`
/// is the sha-256 leaf of the quarantine path (the id restore_quarantine takes);
/// `containment` distinguishes an actually-quarantined file from a reported-only
/// one on a read-only volume (5g).
public struct QuarantineRecordDTO: Codable, Sendable {
    public var quarantineId: String
    public var filePath: String
    public var signature: String
    public var restored: Bool
    public var containment: String    // "quarantined" | "reported_only"
    public init(quarantineId: String, filePath: String, signature: String, restored: Bool, containment: String) {
        self.quarantineId = quarantineId; self.filePath = filePath
        self.signature = signature; self.restored = restored; self.containment = containment
    }
}

/// A full scan (scan.get). Reconciled to the UI/03 shape: per-file `verdicts` and
/// `quarantine` records (built from scan_findings), a `progress` while running,
/// and a `reason` sentence on the non-clean terminal states (5c/5f).
public struct ScanDTO: Codable, Sendable {
    public var scanId: String
    public var deviceId: String?
    public var volumePath: String?
    public var engine: String?
    public var defsAgeDays: Int?
    public var state: String
    public var progress: Double?
    public var startedAt: String
    public var finishedAt: String?
    public var filesScanned: Int
    public var startedBy: String
    public var verdicts: [ScanVerdictDTO]
    public var quarantine: [QuarantineRecordDTO]
    public var reason: String?
}

public struct ScanCancelParams: Codable, Sendable {
    public var scanId: String
}

public struct ScansFilter: Codable, Sendable {
    public var deviceId: String?
}

public struct ScansListParams: Codable, Sendable {
    public var filter: ScansFilter?
    public var limit: Int?
    public var cursor: String?
}

/// One scans.list row. Carries its facts (times, and the `reason` sentence for
/// the non-clean terminal states, 5c/5f) so a list can say WHY a scan failed or
/// was skipped without a scan.get round trip per row.
public struct ScanSummary: Codable, Sendable {
    public var scanId: String
    public var deviceId: String?
    public var volumePath: String
    public var engine: String
    public var state: String
    public var startedAt: String
    public var finishedAt: String?
    public var filesScanned: Int
    /// Non-blank for failed/skipped/canceled; nil where the state word already
    /// says it (running/clean/infected). Same source as ScanDTO.reason.
    public var reason: String?
}

public struct ScansListResult: Codable, Sendable {
    public var scans: [ScanSummary]
    public var nextCursor: String?
}

// MARK: - quarantine.restore (D6: full agent+human parity on un-quarantining)

/// `confirm` is optional on the wire so a missing/false value is caught as
/// `invalid_params` (a deliberate-act gate), not a JSON decoding failure.
public struct QuarantineRestoreParams: Codable, Sendable {
    public var quarantineId: String
    public var confirm: Bool?
}

/// The updated quarantine record after a restore: which finding, the original
/// path the file was moved back to, the new state, and the explicit-risk sentence
/// (03) so an agent quoting the result surfaces the risk. `event` is the appended
/// `quarantine.restored` timeline row.
public struct QuarantineRestoreResult: Codable, Sendable {
    public var quarantineId: String
    public var scanId: String
    public var deviceId: String?
    public var originalPath: String
    public var signature: String
    public var state: String
    public var risk: String
    public var event: TimelineEvent
}

// MARK: - policy

/// Canonical policy object v1 (spec: N4 node doc + 06). N7 reads the same keys.
public struct PolicyObject: Codable, Sendable, Equatable {
    public var scanOnMount: Bool
    public var quarantine: Bool
    public var holdUntilScanned: Bool
    public var scanTimeoutMinutes: Int
    public var clamdSocketPath: String?
    public var definitionsWarnDays: Int
    public var retentionDays: Int
    /// Notify when a device enters yellow or red (04 notification model,
    /// D-notify). Default on: the core promise.
    public var notifyUnsafe: Bool
    /// Also notify on every first attach of a device. Default off.
    public var notifyNewDevice: Bool
    /// RETIRED (D-notify): the legacy 3-level threshold, still SERVED so old
    /// readers decode unchanged, but writes are rejected naming the two new
    /// keys. A stored legacy value migrates once into notifyUnsafe /
    /// notifyNewDevice on the first policy read.
    public var notificationThreshold: String

    public static let defaults = PolicyObject(
        scanOnMount: true,
        quarantine: true,
        holdUntilScanned: false,
        scanTimeoutMinutes: 15,
        clamdSocketPath: nil,
        definitionsWarnDays: 7,
        retentionDays: 365,
        notifyUnsafe: true,
        notifyNewDevice: false,
        notificationThreshold: "warning"
    )

    /// The legacy notification-threshold wire values (still recognized when
    /// SERVING a stored value and when migrating it; never on writes).
    public static let notificationThresholds: Set<String> = ["critical", "warning", "everything"]
}
