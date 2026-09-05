// DTOs.swift
//
// Codable value types that decode the JSON shapes the local API returns (03).
// Both faces (this app and @plugsight/mcp) consume the SAME API, so these
// shapes are the contract restated on the Swift side. They are deliberately
// forgiving on optional fields the daemon may omit, but the required keys track
// 03 exactly.
//
// These are transport DTOs. View models translate them into the surface states
// 04 mandates; nothing here decides UI.

import Foundation

// MARK: - status.get

public struct StatusDTO: Codable, Equatable, Sendable {
    public enum Monitoring: String, Codable, Sendable {
        case active, degraded, stopped
    }
    public enum ExtensionState: String, Codable, Sendable {
        case active, inactive
        case notInstalled = "not_installed"
    }
    public struct Permissions: Codable, Equatable, Sendable {
        public var inputMonitoring: Bool
        /// Whether the typing-rhythm SENSOR is actually collecting:
        /// "active" | "restart_required" (permission granted, but the sensor only
        /// opens at daemon start) | "off". Optional so an older daemon that omits
        /// the key still decodes; nil reads as unknown, never as a fake state.
        public var inputMonitoringSensor: String?
        public var esExtension: ExtensionState
        public init(inputMonitoring: Bool, inputMonitoringSensor: String? = nil,
                    esExtension: ExtensionState) {
            self.inputMonitoring = inputMonitoring
            self.inputMonitoringSensor = inputMonitoringSensor
            self.esExtension = esExtension
        }
    }
    public struct Scanner: Codable, Equatable, Sendable {
        /// One-click ClamAV install progress (onboarding scanner step). Mirrors
        /// the daemon's `installState`: "idle" | "installing" | "failed" | "done".
        public enum InstallState: String, Codable, Sendable {
            case idle, installing, failed, done
        }
        public var available: Bool
        public var engine: String?
        /// nil renders as the "unknown" muted state (04 Settings scanner row).
        public var definitionsAgeDays: Int?
        /// The install progress the onboarding scanner step and Settings poll.
        /// Defaults to `.idle` so an older daemon that omits it still decodes.
        public var installState: InstallState
        /// The latest progress line, or the error tail on failure; nil when idle.
        public var installDetail: String?
        public init(available: Bool, engine: String?, definitionsAgeDays: Int?,
                    installState: InstallState = .idle, installDetail: String? = nil) {
            self.available = available
            self.engine = engine
            self.definitionsAgeDays = definitionsAgeDays
            self.installState = installState
            self.installDetail = installDetail
        }

        // Forgiving decode: tolerate a daemon that omits the install fields, or an
        // unknown installState string, by falling back to `.idle`.
        enum CodingKeys: String, CodingKey {
            case available, engine, definitionsAgeDays, installState, installDetail
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.available = try c.decode(Bool.self, forKey: .available)
            self.engine = try c.decodeIfPresent(String.self, forKey: .engine)
            self.definitionsAgeDays = try c.decodeIfPresent(Int.self, forKey: .definitionsAgeDays)
            let raw = try c.decodeIfPresent(String.self, forKey: .installState)
            self.installState = raw.flatMap(InstallState.init(rawValue:)) ?? .idle
            self.installDetail = try c.decodeIfPresent(String.self, forKey: .installDetail)
        }
    }
    public struct Gap: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public var monitoring: Monitoring
    public var daemonVersion: String
    public var permissions: Permissions
    public var scanner: Scanner
    public var devicesPresent: Int
    public var activeAlerts: Int
    public var monitoringGaps: [Gap]

    public init(monitoring: Monitoring, daemonVersion: String, permissions: Permissions,
                scanner: Scanner, devicesPresent: Int, activeAlerts: Int, monitoringGaps: [Gap]) {
        self.monitoring = monitoring
        self.daemonVersion = daemonVersion
        self.permissions = permissions
        self.scanner = scanner
        self.devicesPresent = devicesPresent
        self.activeAlerts = activeAlerts
        self.monitoringGaps = monitoringGaps
    }
}

// MARK: - devices.list / devices.get

public struct DeviceScoreDTO: Codable, Equatable, Sendable {
    public var value: Int
    public var confidence: String
    public init(value: Int, confidence: String) { self.value = value; self.confidence = confidence }
}

/// The most recent scan for a device (devices.list): state + finish time, so a
/// row can say "last scan clean" without a scans.list round trip. Mirrors the
/// daemon's LastScanBrief.
public struct LastScanDTO: Codable, Equatable, Sendable {
    public var scanId: String
    public var state: ScanDTO.State
    public var finishedAt: String?
    public init(scanId: String, state: ScanDTO.State, finishedAt: String?) {
        self.scanId = scanId
        self.state = state
        self.finishedAt = finishedAt
    }
}

/// One reason inside a device's safety verdict (04 verdict model): a stable id,
/// a plain-language sentence (what happened and why), and exactly one
/// recommended action. `action` stays a raw string here so an older app decodes
/// a newer daemon's vocabulary without failing; known values today: scanAgain,
/// installScanner, grantInputMonitoring, restartDaemon, reviewQuarantine,
/// reviewAlerts, updateDefinitions, unplug, none.
public struct SafetyReasonDTO: Codable, Equatable, Sendable {
    public var id: String
    public var sentence: String
    public var action: String
    public init(id: String, sentence: String, action: String) {
        self.id = id; self.sentence = sentence; self.action = action
    }
}

/// The derived per-device verdict (04 verdict model), mirrored from the
/// daemon's SafetyStatus: `status` is "green" | "yellow" | "red" | "grey",
/// `reasons` are ordered most severe first. Decode-only and additive: absent
/// on an older daemon, so it is optional on the device DTOs.
public struct SafetyStatusDTO: Codable, Equatable, Sendable {
    public var status: String
    public var reasons: [SafetyReasonDTO]
    public init(status: String, reasons: [SafetyReasonDTO]) {
        self.status = status; self.reasons = reasons
    }
}

public struct DeviceSummaryDTO: Codable, Equatable, Sendable {
    public var deviceId: String
    public var name: String
    public var present: Bool
    public var firstSeen: String
    public var lastSeen: String
    public var vidPid: String
    public var serial: String?
    public var interfaceClasses: [String]
    public var trust: String
    /// null-not-zero: absent when the sensor never observed this device (04).
    public var score: DeviceScoreDTO?
    public var activeAlerts: Int
    /// Present while a scan runs; drives the Devices row "Scanning…" status.
    public var scanning: Bool?
    /// The most recent scan, nil when the device was never scanned.
    public var lastScan: LastScanDTO?
    /// The derived verdict (04 verdict model); nil on an older daemon.
    public var safetyStatus: SafetyStatusDTO?

    public init(deviceId: String, name: String, present: Bool, firstSeen: String, lastSeen: String,
                vidPid: String, serial: String?, interfaceClasses: [String], trust: String,
                score: DeviceScoreDTO?, activeAlerts: Int, scanning: Bool? = nil,
                lastScan: LastScanDTO? = nil, safetyStatus: SafetyStatusDTO? = nil) {
        self.deviceId = deviceId
        self.name = name
        self.present = present
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.vidPid = vidPid
        self.serial = serial
        self.interfaceClasses = interfaceClasses
        self.trust = trust
        self.score = score
        self.activeAlerts = activeAlerts
        self.scanning = scanning
        self.lastScan = lastScan
        self.safetyStatus = safetyStatus
    }
}

public struct DeviceListDTO: Codable, Equatable, Sendable {
    public var devices: [DeviceSummaryDTO]
    public var nextCursor: String?
    public init(devices: [DeviceSummaryDTO], nextCursor: String?) {
        self.devices = devices
        self.nextCursor = nextCursor
    }
}

public struct InterfaceRowDTO: Codable, Equatable, Sendable {
    public var seq: Int
    public var usbClass: Int
    public var subclass: Int
    public var proto: Int
    public var role: String
    public init(seq: Int = 0, usbClass: Int, subclass: Int, proto: Int, role: String) {
        self.seq = seq; self.usbClass = usbClass; self.subclass = subclass; self.proto = proto; self.role = role
    }
    enum CodingKeys: String, CodingKey {
        case seq, usbClass = "class", subclass, proto = "protocol", role
    }
}

/// Device topology (port + hub path) from devices.get (03). `port` is the full
/// bus/port string; `hubPath` the parsed hub hops. Absent for devices whose port
/// was never recorded.
public struct TopologyDTO: Codable, Equatable, Sendable {
    public var port: String
    public var hubPath: [String]
    public init(port: String, hubPath: [String]) { self.port = port; self.hubPath = hubPath }
}

public struct TrustHistoryDTO: Codable, Equatable, Sendable {
    public var tier: String
    public var actor: String
    public var at: String
    public var note: String?
    public init(tier: String, actor: String, at: String, note: String?) {
        self.tier = tier; self.actor = actor; self.at = at; self.note = note
    }
}

public struct DeviceDetailDTO: Codable, Equatable, Sendable {
    public var deviceId: String
    public var name: String
    public var present: Bool
    public var firstSeen: String
    public var lastSeen: String
    public var vidPid: String
    public var serial: String?
    public var trust: String
    public var interfaces: [InterfaceRowDTO]
    public var topology: TopologyDTO?
    public var trustHistory: [TrustHistoryDTO]
    /// Only for storage devices; drives the inspector-header Eject control.
    public var isStorage: Bool
    /// The derived verdict (04 verdict model); nil on an older daemon.
    public var safetyStatus: SafetyStatusDTO?

    public init(deviceId: String, name: String, present: Bool, firstSeen: String, lastSeen: String,
                vidPid: String, serial: String?, trust: String, interfaces: [InterfaceRowDTO],
                topology: TopologyDTO?, trustHistory: [TrustHistoryDTO], isStorage: Bool,
                safetyStatus: SafetyStatusDTO? = nil) {
        self.deviceId = deviceId
        self.name = name
        self.present = present
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.vidPid = vidPid
        self.serial = serial
        self.trust = trust
        self.interfaces = interfaces
        self.topology = topology
        self.trustHistory = trustHistory
        self.isStorage = isStorage
        self.safetyStatus = safetyStatus
    }
}

// MARK: - timeline.list / events.get

public struct EventDTO: Codable, Equatable, Sendable {
    public var eventId: String
    public var at: String
    public var kind: String
    public var severity: String
    public var deviceId: String?
    public var summary: String
    public var actor: String
    /// The event's structured detail (raw JSON string, additive on the wire).
    /// monitoring.gap carries {"from","to"} here, which the UI formats in the
    /// viewer's timezone instead of echoing the summary's UTC ISO stamps.
    public var detail: String?
    public init(eventId: String, at: String, kind: String, severity: String,
                deviceId: String?, summary: String, actor: String,
                detail: String? = nil) {
        self.eventId = eventId
        self.at = at
        self.kind = kind
        self.severity = severity
        self.deviceId = deviceId
        self.summary = summary
        self.actor = actor
        self.detail = detail
    }
}

public struct TimelineDTO: Codable, Equatable, Sendable {
    public var events: [EventDTO]
    public var nextCursor: String?
    public init(events: [EventDTO], nextCursor: String?) {
        self.events = events
        self.nextCursor = nextCursor
    }
}

public struct SuggestedActionDTO: Codable, Equatable, Sendable {
    public var tool: String
    public var label: String
    public init(tool: String, label: String) { self.tool = tool; self.label = label }
}

public struct EventExplanationDTO: Codable, Equatable, Sendable {
    public var event: EventDTO
    public var why: String
    public var suggestedActions: [SuggestedActionDTO]
    public init(event: EventDTO, why: String, suggestedActions: [SuggestedActionDTO]) {
        self.event = event
        self.why = why
        self.suggestedActions = suggestedActions
    }
}

// MARK: - score.get

public struct ScoreSignalDTO: Codable, Equatable, Sendable {
    public var id: String
    public var observed: String
    public var verdict: String
    public var weight: Double
    public init(id: String, observed: String, verdict: String, weight: Double) {
        self.id = id; self.observed = observed; self.verdict = verdict; self.weight = weight
    }
}

public struct ScoreDTO: Codable, Equatable, Sendable {
    /// null when the sensor is off OR nothing was observed — never a fabricated
    /// zero (04 null-not-zero). A NUMBER exists only when `sensorAvailable` and
    /// `score != nil`.
    public var score: Int?
    public var confidence: String?
    public var signals: [ScoreSignalDTO]
    public var explanation: String?
    public var caveat: String
    /// Whether Input Monitoring is granted (04 4b/4c). When false the card says
    /// "sensor off" rather than "no typing observed".
    public var sensorAvailable: Bool

    public init(score: Int?, confidence: String?, signals: [ScoreSignalDTO], explanation: String?,
                caveat: String, sensorAvailable: Bool) {
        self.score = score
        self.confidence = confidence
        self.signals = signals
        self.explanation = explanation
        self.caveat = caveat
        self.sensorAvailable = sensorAvailable
    }
}

// MARK: - alerts.list

public struct AlertDTO: Codable, Equatable, Sendable {
    public var alertId: String
    public var state: String  // active | acknowledged | resolved
    public var severity: String
    public var deviceId: String?
    public var deviceName: String
    public var summary: String
    public var why: String
    public var at: String
    public var suggestedActions: [SuggestedActionDTO]
    public init(alertId: String, state: String, severity: String, deviceId: String?,
                deviceName: String, summary: String, why: String, at: String,
                suggestedActions: [SuggestedActionDTO]) {
        self.alertId = alertId
        self.state = state
        self.severity = severity
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.summary = summary
        self.why = why
        self.at = at
        self.suggestedActions = suggestedActions
    }
}

public struct AlertListDTO: Codable, Equatable, Sendable {
    public var alerts: [AlertDTO]
    public var nextCursor: String?
    public init(alerts: [AlertDTO], nextCursor: String?) {
        self.alerts = alerts
        self.nextCursor = nextCursor
    }
}

// MARK: - scan.get / scans

public struct QuarantineRecordDTO: Codable, Equatable, Sendable {
    public var quarantineId: String
    public var filePath: String
    public var signature: String
    public var restored: Bool
    /// "quarantined" | "reported_only" (read-only volume; 5g).
    public var containment: String
    public init(quarantineId: String, filePath: String, signature: String, restored: Bool, containment: String) {
        self.quarantineId = quarantineId
        self.filePath = filePath
        self.signature = signature
        self.restored = restored
        self.containment = containment
    }
}

public struct ScanVerdictDTO: Codable, Equatable, Sendable {
    public var filePath: String
    public var verdict: String  // clean | infected
    public var signature: String?
    public init(filePath: String, verdict: String, signature: String?) {
        self.filePath = filePath; self.verdict = verdict; self.signature = signature
    }
}

public struct ScanDTO: Codable, Equatable, Sendable {
    /// Exactly the states 04/03 permit — canceled is never rendered clean.
    public enum State: String, Codable, Sendable {
        case running, clean, infected, failed, canceled, skipped
    }
    public var scanId: String
    public var deviceId: String?
    public var volumePath: String?
    public var state: State
    public var engine: String?
    /// 0...1 while running (5d); nil for terminal states.
    public var progress: Double?
    public var startedAt: String
    public var verdicts: [ScanVerdictDTO]
    public var quarantine: [QuarantineRecordDTO]
    /// Reason string on failed/skipped (5c/5f) — never blank.
    public var reason: String?

    public init(scanId: String, deviceId: String?, volumePath: String?, state: State, engine: String?,
                progress: Double?, startedAt: String, verdicts: [ScanVerdictDTO],
                quarantine: [QuarantineRecordDTO], reason: String?) {
        self.scanId = scanId
        self.deviceId = deviceId
        self.volumePath = volumePath
        self.state = state
        self.engine = engine
        self.progress = progress
        self.startedAt = startedAt
        self.verdicts = verdicts
        self.quarantine = quarantine
        self.reason = reason
    }
}

/// The result of scan.start (03: `{ scanId, state:"running" }`). A scan is
/// polled via scan.get / scans.list afterwards.
public struct ScanStartedDTO: Codable, Equatable, Sendable {
    public var scanId: String
    public var state: ScanDTO.State
    public init(scanId: String, state: ScanDTO.State) { self.scanId = scanId; self.state = state }
}

/// A scan summary row (scans.list). The list returns SUMMARIES only (03/04);
/// full per-file verdicts and quarantine records come from scan.get.
public struct ScanSummaryDTO: Codable, Equatable, Sendable {
    public var scanId: String
    public var deviceId: String?
    public var state: ScanDTO.State
    public var engine: String?
    public var startedAt: String
    public var finishedAt: String?
    public var filesScanned: Int
    /// Non-blank on failed/skipped/canceled rows (5c/5f); nil where the state
    /// word already says it. Mirrors the daemon's ScanSummary.reason.
    public var reason: String?
    public init(scanId: String, deviceId: String?, state: ScanDTO.State, engine: String?,
                startedAt: String, finishedAt: String?, filesScanned: Int, reason: String? = nil) {
        self.scanId = scanId
        self.deviceId = deviceId
        self.state = state
        self.engine = engine
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.filesScanned = filesScanned
        self.reason = reason
    }
}

public struct ScanListDTO: Codable, Equatable, Sendable {
    public var scans: [ScanSummaryDTO]
    public var nextCursor: String?
    public init(scans: [ScanSummaryDTO], nextCursor: String? = nil) {
        self.scans = scans
        self.nextCursor = nextCursor
    }
}

/// The result of quarantine.restore (D6): the restored file's original path, its
/// signature, the new state, and the explicit-risk sentence the caller surfaces.
public struct QuarantineRestoreResultDTO: Codable, Equatable, Sendable {
    public var quarantineId: String
    public var scanId: String
    public var deviceId: String?
    public var originalPath: String
    public var signature: String
    public var state: String
    public var risk: String
    public var event: EventDTO
    public init(quarantineId: String, scanId: String, deviceId: String?, originalPath: String,
                signature: String, state: String, risk: String, event: EventDTO) {
        self.quarantineId = quarantineId
        self.scanId = scanId
        self.deviceId = deviceId
        self.originalPath = originalPath
        self.signature = signature
        self.state = state
        self.risk = risk
        self.event = event
    }
}

// MARK: - policy.get / policy.set

/// The policy object (policy.get). The UI decodes the subset it renders from the
/// canonical wire keys (06): `holdUntilScanned` (mapped to the "Hold new drives
/// until scanned" toggle) and `notificationThreshold` (the picker). Other
/// canonical keys the daemon emits are ignored here.
public struct PolicyDTO: Codable, Equatable, Sendable {
    public var scanOnMount: Bool
    public var holdUntilScanned: Bool
    /// "critical" | "warning" | "everything" — the self-describing threshold (04).
    public var notificationThreshold: String
    /// The two Wave-2 notification keys (04 notification model). Optional and
    /// decode-forgiving: a daemon that predates them omits the keys and this
    /// decodes to nil. Use sites treat nil as the defaults (notifyUnsafe → true,
    /// notifyNewDevice → false), so the app behaves identically with or without
    /// the keys on the wire.
    public var notifyUnsafe: Bool?
    public var notifyNewDevice: Bool?
    public init(scanOnMount: Bool, holdUntilScanned: Bool, notificationThreshold: String,
                notifyUnsafe: Bool? = nil, notifyNewDevice: Bool? = nil) {
        self.scanOnMount = scanOnMount
        self.holdUntilScanned = holdUntilScanned
        self.notificationThreshold = notificationThreshold
        self.notifyUnsafe = notifyUnsafe
        self.notifyNewDevice = notifyNewDevice
    }
}
