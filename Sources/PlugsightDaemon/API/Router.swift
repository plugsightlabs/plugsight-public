// Router.swift
//
// Method routing for the local API (02's method table). Each method decodes its
// typed params (APITypes), calls the store (EventStore + EventStore+API), and
// encodes the frozen result shape. Mutations stamp the connection's `actor` into
// the events they append and fan them out over the broadcaster.

import Foundation
import PlugsightCore

final class Router {
    private let store: APIStore
    private let broadcaster: EventBroadcaster
    private let daemonVersion: String
    private let capabilities: Capabilities
    private let startedAt: Date
    /// Where quarantined files + sidecars live (02); the restore mover reverses a
    /// containment out of this directory.
    private let quarantineDirectory: String

    /// When present, `scan.start` drives a REAL scan through the ScanOrchestrator
    /// (N8b Gap A). When absent (pure routing unit tests), `scan.start` records a
    /// placeholder `running` scan as before.
    private let scanCoordinator: ScanCoordinator?

    /// Re-resolves the ClamAV engine on demand (injected from boot wiring), so
    /// status.get reflects an engine installed or removed while the daemon runs.
    /// Returns the resolved engine name ("clamdscan"/"clamscan"), nil when no
    /// engine resolves. Nil resolver (pure routing unit tests) falls back to the
    /// boot-time capability flag.
    private let clamavResolver: (@Sendable () -> String?)?

    /// Computes the REAL definitions age in whole days from the freshclam
    /// database mtimes (injected from boot wiring). Nil resolver (pure routing
    /// unit tests) reports a nil age, as before.
    private let definitionsAgeResolver: (@Sendable () -> Int?)?

    /// Performs and tracks the one-click ClamAV install (onboarding scanner
    /// step). status.get reads its progress; `scanner.install` starts it. Nil in
    /// pure routing unit tests, where `scanner.install` reports it unavailable.
    private let scannerInstaller: ScannerInstaller?

    /// Re-checks the Input Monitoring PERMISSION on demand (injected from boot
    /// wiring, where it wraps CGPreflightListenEventAccess). Nil resolver (pure
    /// routing unit tests) falls back to the boot-time capability flag. The HID
    /// sensor itself still opens only at daemon start; `inputMonitoringSensor`
    /// reports that honestly.
    private let inputMonitoringResolver: (@Sendable () -> Bool)?

    /// Reports whether the ES extension's XPC handshake is LIVE right now
    /// (injected from boot wiring, where it wraps
    /// ESExtensionXPCClient.handshakeActive: true only while the last policy
    /// push was acknowledged recently). Nil resolver (pure routing unit
    /// tests, and daemons wired without an ES client) falls back to the
    /// boot-time capability flag, which honest boot wiring sets false.
    private let esActiveResolver: (@Sendable () -> Bool)?

    /// Endpoint security truth for status.get: a live handshake, or the boot
    /// flag when no resolver is wired. Never a hardcoded value.
    private var resolvedESActive: Bool {
        esActiveResolver?() ?? capabilities.endpointSecurity
    }

    /// Fired after a successful policy.set or trust.set commit, so the ES
    /// policy pusher can push a fresh snapshot to the extension immediately
    /// instead of waiting for its heartbeat (the hold flag and the trust
    /// table are exactly what the AUTH_MOUNT decision reads). Optional: pure
    /// routing unit tests leave it nil.
    var onPolicyOrTrustChanged: (@Sendable () -> Void)?

    /// The Input Monitoring permission: FRESH when a resolver is wired, else
    /// the boot snapshot.
    private var resolvedInputMonitoring: Bool {
        inputMonitoringResolver?() ?? capabilities.inputMonitoring
    }

    /// The scanner engine: FRESH when a resolver is wired, else derived from the
    /// boot flag (which never knew the engine name, so it keeps the historical
    /// "clamdscan" answer for the pure routing tests).
    private var resolvedScannerEngine: String? {
        if let clamavResolver { return clamavResolver() }
        return capabilities.clamav ? "clamdscan" : nil
    }

    init(store: APIStore, broadcaster: EventBroadcaster, daemonVersion: String,
         capabilities: Capabilities, startedAt: Date,
         quarantineDirectory: String,
         scanCoordinator: ScanCoordinator? = nil,
         clamavResolver: (@Sendable () -> String?)? = nil,
         definitionsAgeResolver: (@Sendable () -> Int?)? = nil,
         scannerInstaller: ScannerInstaller? = nil,
         inputMonitoringResolver: (@Sendable () -> Bool)? = nil,
         esActiveResolver: (@Sendable () -> Bool)? = nil) {
        self.store = store
        self.broadcaster = broadcaster
        self.daemonVersion = daemonVersion
        self.capabilities = capabilities
        self.startedAt = startedAt
        self.quarantineDirectory = quarantineDirectory
        self.scanCoordinator = scanCoordinator
        self.clamavResolver = clamavResolver
        self.definitionsAgeResolver = definitionsAgeResolver
        self.scannerInstaller = scannerInstaller
        self.inputMonitoringResolver = inputMonitoringResolver
        self.esActiveResolver = esActiveResolver
    }

    // MARK: - auth.hello (handled specially by the server before authentication)

    func handleHello(request: RPCRequest, conn: APIConnection, token: String) throws -> Data {
        if conn.authenticated {
            throw APIError.invalidParams("Already authenticated; auth.hello may be sent only once per connection.")
        }
        let params = try (request.params ?? .object([:])).decoded(HelloParams.self)
        guard constantTimeEqual(params.token, token) else {
            throw APIError.unauthorized("Unauthorized: the API token did not match. Read it from ~/Library/Application Support/Plugsight/api-token.")
        }
        conn.authenticated = true
        conn.actor = Self.actor(from: params.clientInfo)
        let result = HelloResult(apiVersion: 1, daemonVersion: daemonVersion, capabilities: capabilities)
        return try RPCEncoder.result(id: request.id, result)
    }

    // MARK: - Authenticated dispatch

    func handle(request: RPCRequest, conn: APIConnection) throws -> Data {
        let params = request.params ?? .object([:])
        switch request.method {
        case "auth.hello":
            throw APIError.invalidParams("Already authenticated; auth.hello may be sent only once per connection.")
        case "status.get":
            return try RPCEncoder.result(id: request.id, statusGet())
        case "devices.list":
            return try RPCEncoder.result(id: request.id, devicesList(try params.decoded(DevicesListParams.self)))
        case "devices.get":
            return try RPCEncoder.result(id: request.id, devicesGet(try params.decoded(DeviceGetParams.self)))
        case "timeline.list":
            return try RPCEncoder.result(id: request.id, timelineList(try params.decoded(TimelineListParams.self)))
        case "events.get":
            return try RPCEncoder.result(id: request.id, eventsGet(try params.decoded(EventGetParams.self)))
        case "score.get":
            return try RPCEncoder.result(id: request.id, scoreGet(try params.decoded(ScoreGetParams.self)))
        case "alerts.list":
            return try RPCEncoder.result(id: request.id, alertsList(try params.decoded(AlertsListParams.self)))
        case "alerts.ack":
            return try RPCEncoder.result(id: request.id, alertsAck(try params.decoded(AlertsAckParams.self), actor: conn.actor))
        case "trust.set":
            return try RPCEncoder.result(id: request.id, trustSet(try params.decoded(TrustSetParams.self), actor: conn.actor))
        case "scan.start":
            return try RPCEncoder.result(id: request.id, scanStart(try params.decoded(ScanStartParams.self), actor: conn.actor))
        case "scan.get":
            return try RPCEncoder.result(id: request.id, scanGet(try params.decoded(ScanGetParams.self)))
        case "scan.cancel":
            return try RPCEncoder.result(id: request.id, scanCancel(try params.decoded(ScanCancelParams.self)))
        case "scans.list":
            return try RPCEncoder.result(id: request.id, scansList(try params.decoded(ScansListParams.self)))
        case "quarantine.restore":
            return try RPCEncoder.result(id: request.id, quarantineRestore(try params.decoded(QuarantineRestoreParams.self), actor: conn.actor))
        case "events.tail":
            return try RPCEncoder.result(id: request.id, eventsTail(try params.decoded(EventsTailParams.self), conn: conn))
        case "events.untail":
            return try RPCEncoder.result(id: request.id, eventsUntail(try params.decoded(EventsUntailParams.self), conn: conn))
        case "policy.get":
            return try RPCEncoder.result(id: request.id, policyGet())
        case "policy.set":
            return try RPCEncoder.result(id: request.id, policySet(params, actor: conn.actor))
        case "scanner.install":
            return try RPCEncoder.result(id: request.id, scannerInstall())
        default:
            throw APIError(code: -32601, message: "Method '\(request.method)' is not implemented.", kind: .invalidParams)
        }
    }

    // MARK: - status.get

    func statusGet() throws -> StatusResult {
        let counts = try store.statusCounts()
        // Fresh per call: a scanner installed (or removed) while the daemon runs
        // must show up on the next status.get, not after a restart. The engine
        // name is whatever discovery resolved (clamdscan vs clamscan), never a
        // hardcoded guess.
        let engineNow = resolvedScannerEngine
        let clamavNow = engineNow != nil
        // Input Monitoring: the PERMISSION is re-checked fresh per call (a grant
        // made while the daemon runs registers here without a restart). The HID
        // sensor itself only opens at daemon start, so `monitoring` counts the
        // BOOT capability — a granted-but-unopened sensor is still degraded —
        // and `inputMonitoringSensor` names that state explicitly.
        let inputPermissionNow = resolvedInputMonitoring
        let sensorLive = capabilities.inputMonitoring
        let sensorState = sensorLive ? "active" : (inputPermissionNow ? "restart_required" : "off")
        // Endpoint security: ACTIVE only on a live, acknowledged XPC handshake
        // with the extension (unit 5); never a hardcoded flag.
        let esActiveNow = resolvedESActive
        let allPresent = sensorLive && esActiveNow && clamavNow
        let monitoring = allPresent ? "active" : "degraded"
        // Real definitions age from the freshclam database mtimes (nil when no
        // resolver is wired, or no database file is present).
        let defsAge = definitionsAgeResolver?()
        // One-click install progress (idle when no installer is wired).
        let install = scannerInstaller?.snapshot() ?? (state: "idle", detail: nil)
        let scanner = ScannerStatus(
            available: clamavNow,
            engine: engineNow,
            definitionsAgeDays: defsAge,
            installState: install.state,
            installDetail: install.detail
        )
        return StatusResult(
            monitoring: monitoring,
            daemonVersion: daemonVersion,
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
            permissions: Permissions(
                inputMonitoring: inputPermissionNow,
                inputMonitoringSensor: sensorState,
                esExtension: esActiveNow ? "active" : "inactive"
            ),
            scanner: scanner,
            devicesPresent: counts.devicesPresent,
            activeAlerts: counts.activeAlerts,
            eventCount: counts.eventCount,
            monitoringGaps: counts.gaps.map { MonitoringGap(from: $0.from, to: $0.to) }
        )
    }

    // MARK: - scanner.install

    /// Start a one-click ClamAV install (app<->daemon RPC only). Params are
    /// ignored (accept empty/absent). Returns accepted:true when the install was
    /// started, else accepted:false with a human reason. Progress is polled via
    /// status.get's installState/installDetail.
    func scannerInstall() -> ScannerInstallResult {
        guard let scannerInstaller else {
            return ScannerInstallResult(
                accepted: false,
                reason: "The installer is not available in this daemon build.")
        }
        let outcome = scannerInstaller.startInstall()
        return ScannerInstallResult(accepted: outcome.accepted, reason: outcome.reason)
    }

    // MARK: - devices.list / devices.get

    func devicesList(_ p: DevicesListParams) throws -> DevicesListResult {
        let limit = p.limit ?? APIStore.maxPageLimit
        let devices = try store.listDevices(
            present: p.filter?.present, trust: p.filter?.trust,
            deviceClass: p.filter?.deviceClass, limit: limit, cursor: p.cursor)
        let context = try safetyContext()   // once per request, not per device
        let summaries = try devices.map { try summary(for: $0, context: context) }
        let next = (devices.count == min(max(limit, 1), APIStore.maxPageLimit)) ? devices.last?.id : nil
        return DevicesListResult(devices: summaries, nextCursor: next)
    }

    func devicesGet(_ p: DeviceGetParams) throws -> DeviceRecord {
        guard let d = try store.getDevice(id: p.deviceId) else {
            throw APIError.notFound("No device with id '\(p.deviceId)'. Use devices.list to see known devices.")
        }
        return try deviceRecord(from: d)
    }

    private func summary(for d: StoredDevice, context: SafetyContext) throws -> DeviceSummary {
        let score = try store.latestScore(deviceID: d.id).map { ScoreBrief(value: $0.score, confidence: $0.confidence) }
        let scanning = try store.hasRunningScan(deviceID: d.id)
        return DeviceSummary(
            deviceId: d.id, name: d.displayName, present: d.present,
            firstSeen: d.firstSeenAt, lastSeen: d.lastSeenAt, vidPid: Self.vidPid(d.vid, d.pid),
            serial: d.serial, interfaceClasses: d.interfaces.map { $0.role }, trust: d.trustTier,
            score: score, activeAlerts: try store.activeAlertCount(deviceID: d.id),
            scanning: scanning,
            lastScan: try lastScanBrief(deviceID: d.id),
            safetyStatus: try safetyStatus(for: d, scanning: scanning, context: context))
    }

    // MARK: - Safety verdict (04 verdict model)

    /// The request-wide facts the per-device verdict needs: sensor state,
    /// scanner availability, definitions age, and the policy knobs. Computed
    /// once per request so devices.list does not re-resolve them per row.
    struct SafetyContext {
        let typingSensor: TypingSensorState
        let scannerAvailable: Bool
        let definitionsAgeDays: Int?
        let definitionsWarnDays: Int
        let scanOnMount: Bool
    }

    func safetyContext() throws -> SafetyContext {
        // Same truths status.get reports: the sensor collects only when it
        // opened at boot; a mid-run grant is restart_required, not active.
        let sensorLive = capabilities.inputMonitoring
        let sensor: TypingSensorState = sensorLive
            ? .active
            : (resolvedInputMonitoring ? .restartRequired : .off)
        let policy = try policyGet()
        return SafetyContext(
            typingSensor: sensor,
            scannerAvailable: resolvedScannerEngine != nil,
            definitionsAgeDays: definitionsAgeResolver?(),
            definitionsWarnDays: policy.definitionsWarnDays,
            scanOnMount: policy.scanOnMount)
    }

    /// Derive one device's SafetyStatus from the store's facts plus the
    /// request context. The derivation itself lives in PlugsightCore so the
    /// app, the MCP payload, and these results can never disagree.
    private func safetyStatus(for d: StoredDevice, scanning: Bool, context: SafetyContext) throws -> SafetyStatus {
        let alerts = try store.activeAlertSeverityCounts(deviceID: d.id)
        let score = try store.latestScore(deviceID: d.id)
        let lastTerminal = try store.latestTerminalScanBrief(deviceID: d.id)
        let inputs = SafetyInputs(
            isStorage: Self.isStorage(d.interfaces),
            hasHIDInterface: Self.isHID(d.interfaces),
            lastScanState: lastTerminal?.state,
            scanning: scanning,
            activeCriticalAlerts: alerts.critical,
            activeWarningAlerts: alerts.warning,
            behaviorScore: score?.score,
            behaviorConfidence: score.flatMap { BehavioralScore.Confidence(rawValue: $0.confidence) },
            typingSensor: context.typingSensor,
            scannerAvailable: context.scannerAvailable,
            scanOnMount: context.scanOnMount,
            definitionsAgeDays: context.definitionsAgeDays,
            definitionsWarnDays: context.definitionsWarnDays)
        return SafetyStatus.derive(inputs)
    }

    /// A device gets the typing check when any interface enumerated as HID
    /// (class 0x03; role words keyboard/mouse and HID "other").
    static func isHID(_ interfaces: [StoredInterface]) -> Bool {
        interfaces.contains { $0.usbClass == 0x03 }
    }

    /// The device's most recent scan as the summary brief; nil when unscanned.
    private func lastScanBrief(deviceID: String) throws -> LastScanBrief? {
        try store.latestScanBrief(deviceID: deviceID).map {
            LastScanBrief(scanId: $0.id, state: $0.state, finishedAt: $0.finishedAt)
        }
    }

    // MARK: - timeline.list / events.get

    func timelineList(_ p: TimelineListParams) throws -> TimelineListResult {
        let limit = p.limit ?? 50
        let events = try store.timeline(
            deviceID: p.filter?.deviceId, kinds: p.filter?.kinds, severity: p.filter?.severity,
            since: p.filter?.since, until: p.filter?.until, limit: limit, cursor: p.cursor)
        let next = (events.count == min(max(limit, 1), APIStore.maxPageLimit)) ? events.last?.id : nil
        return TimelineListResult(events: events.map(Self.timelineEvent(from:)), nextCursor: next)
    }

    func eventsGet(_ p: EventGetParams) throws -> EventDetailResult {
        guard let e = try store.getEvent(id: p.eventId) else {
            throw APIError.notFound("No event with id '\(p.eventId)'.")
        }
        // `why` names the rule/signal behind the event: the alert's reasoning when
        // it belongs to one, otherwise the event's own plain summary (never blank).
        let alertWhy = try e.alertID.flatMap { try store.alertWhy(alertID: $0) }
        let why = alertWhy ?? e.summary
        let device = try e.deviceID.flatMap { try store.getDevice(id: $0) }
        let context = EventContext(
            detail: JSONValue.parse(e.detail), deviceId: e.deviceID,
            deviceName: device?.displayName, trust: device?.trustTier, alertId: e.alertID)
        return EventDetailResult(
            event: Self.timelineEvent(from: e), why: why, context: context,
            suggestedActions: Self.eventActions(kind: e.kind, hasDevice: e.deviceID != nil, hasAlert: e.alertID != nil))
    }

    /// The suggested next actions for an event, each naming its tool (03: every
    /// explanation names a next action — no dead ends).
    static func eventActions(kind: String, hasDevice: Bool, hasAlert: Bool) -> [SuggestedAction] {
        var actions: [SuggestedAction] = []
        if hasAlert { actions.append(SuggestedAction(tool: "acknowledge_alert", label: "Acknowledge the alert")) }
        if hasDevice {
            actions.append(SuggestedAction(tool: "get_device", label: "Inspect the device"))
            actions.append(SuggestedAction(tool: "flag_device", label: "Flag the device"))
        }
        if actions.isEmpty { actions.append(SuggestedAction(tool: "get_timeline", label: "See related events")) }
        return actions
    }

    // MARK: - score.get

    static let scoreCaveat = "Behavioral scoring is probabilistic and a patient attacker can evade it."

    func scoreGet(_ p: ScoreGetParams) throws -> ScoreResult {
        guard try store.getDevice(id: p.deviceId) != nil else {
            throw APIError.notFound("No device with id '\(p.deviceId)'.")
        }
        // The sensor collects only when it opened at boot; a permission granted
        // mid-run does not reopen it (HIDTimingSource opens once at start).
        let sensorAvailable = capabilities.inputMonitoring
        // Null-not-zero (04 4b/4c): when the sensor is off there is NO number, and
        // the payload says the sensor is off rather than showing a fabricated 0.
        guard sensorAvailable else {
            // Honest reason: distinguish "not granted" from "granted mid-run,
            // needs a daemon restart to start collecting".
            let explanation = resolvedInputMonitoring
                ? "Input Monitoring is granted, but the daemon needs a restart to start reading typing rhythm."
                : "Typing behavior is not scored because Input Monitoring is not granted."
            return ScoreResult(
                score: nil, confidence: nil, signals: [],
                explanation: explanation,
                caveat: Self.scoreCaveat, sensorAvailable: false)
        }
        guard let snap = try store.latestScore(deviceID: p.deviceId) else {
            // Sensor on, but this device has never been observed typing — still no
            // number (null-not-zero), just an honest reason. Never a dead end.
            return ScoreResult(
                score: nil, confidence: nil, signals: [],
                explanation: "No typing has been observed from this device yet.",
                caveat: Self.scoreCaveat, sensorAvailable: true)
        }
        let signals = (try? JSONDecoder().decode([ScoreSignal].self, from: Data(snap.signals.utf8))) ?? []
        return ScoreResult(
            score: snap.score, confidence: snap.confidence, signals: signals,
            explanation: "Score \(snap.score) (\(snap.confidence) confidence) from \(signals.count) signal(s).",
            caveat: Self.scoreCaveat, sensorAvailable: true)
    }

    // MARK: - alerts.list / alerts.ack

    func alertsList(_ p: AlertsListParams) throws -> AlertsListResult {
        let limit = p.limit ?? APIStore.maxPageLimit
        let alerts = try store.listAlerts(state: p.filter?.state, severity: p.filter?.severity,
                                          deviceID: p.filter?.deviceId, limit: limit, cursor: p.cursor)
        let next = (alerts.count == min(max(limit, 1), APIStore.maxPageLimit)) ? alerts.last?.id : nil
        return AlertsListResult(alerts: try alerts.map { try alertDTO(from: $0) }, nextCursor: next)
    }

    func alertsAck(_ p: AlertsAckParams, actor: String) throws -> AlertsAckResult {
        guard let existing = try store.getAlert(id: p.alertId) else {
            throw APIError.notFound("No alert with id '\(p.alertId)'.")
        }
        guard existing.state == "active" else {
            throw APIError.conflict("Alert '\(p.alertId)' is already \(existing.state); only active alerts can be acknowledged.",
                                    extraData: ["state": .string(existing.state)])
        }
        let updated = try store.acknowledgeAlert(id: p.alertId, comment: p.comment, actor: actor)
        let summary = "Alert acknowledged by \(actor)." + (p.comment.map { " \($0)" } ?? "")
        let detail = "{\"v\":1,\"alertId\":\"\(p.alertId)\"}"
        let event = try store.appendEvent(kind: "alert.acknowledged", severity: mirrorSeverity(updated.severity),
                                          deviceID: updated.deviceID, actor: actor, summary: summary,
                                          detail: detail, alertID: p.alertId)
        return AlertsAckResult(alert: try alertDTO(from: updated), event: Self.timelineEvent(from: event))
    }

    /// Alert severities are notice/warning/critical; the events table also allows
    /// info. Map alert severity onto a valid event severity (identity here).
    private func mirrorSeverity(_ s: String) -> String {
        ["notice", "warning", "critical", "info"].contains(s) ? s : "notice"
    }

    /// Build the reconciled alert shape: the resolved device name, the `at`
    /// timestamp, and the suggested next actions (03: no dead ends).
    func alertDTO(from a: StoredAlert) throws -> AlertDTO {
        let deviceName = try a.deviceID.flatMap { try store.getDevice(id: $0)?.displayName } ?? "System"
        return AlertDTO(
            alertId: a.id, deviceId: a.deviceID, deviceName: deviceName, rule: a.rule,
            severity: a.severity, state: a.state, at: a.raisedAt, raisedAt: a.raisedAt,
            updatedAt: a.updatedAt, summary: a.summary, why: a.why,
            suggestedActions: Self.alertActions(state: a.state),
            ackedBy: a.ackedBy, ackedAt: a.ackedAt, ackComment: a.ackComment)
    }

    /// The next actions an alert names, keyed on its state (each names its tool).
    static func alertActions(state: String) -> [SuggestedAction] {
        switch state {
        case "active":
            return [SuggestedAction(tool: "acknowledge_alert", label: "Acknowledge"),
                    SuggestedAction(tool: "flag_device", label: "Flag device")]
        default:
            return [SuggestedAction(tool: "flag_device", label: "Flag device")]
        }
    }

    // MARK: - trust.set

    static let trustCaveat = "Trust is advisory: a device's identity can be forged, so a trusted mark is not proof of safety."
    private static let validTiers: Set<String> = ["trusted", "muted", "flagged", "none"]

    func trustSet(_ p: TrustSetParams, actor: String) throws -> TrustSetResult {
        guard Self.validTiers.contains(p.tier) else {
            throw APIError.invalidParams("Parameter 'tier' must be one of trusted, muted, flagged, none (got '\(p.tier)').")
        }
        guard let before = try store.getDevice(id: p.deviceId) else {
            throw APIError.notFound("No device with id '\(p.deviceId)'. Trusting an absent device is allowed only once it has been seen.")
        }
        let oldTier = before.trustTier
        let updated = try store.setTrust(deviceID: p.deviceId, tier: p.tier, note: p.note, actor: actor)
        let summary = "Trust set to \(p.tier) by \(actor)." + (p.note.map { " '\($0)'" } ?? "")
        let detail = Self.trustChangedDetail(from: oldTier, to: p.tier, note: p.note)
        let event = try store.appendEvent(kind: "trust.changed", severity: "info", deviceID: p.deviceId,
                                          actor: actor, summary: summary, detail: detail)
        let record = try deviceRecord(from: updated)
        onPolicyOrTrustChanged?()
        return TrustSetResult(device: record, event: Self.timelineEvent(from: event), caveat: Self.trustCaveat)
    }

    // MARK: - events.tail / events.untail

    private func eventsTail(_ p: EventsTailParams, conn: APIConnection) throws -> EventsTailResult {
        let id = broadcaster.subscribe(filter: p.filter) { [weak conn] event in
            guard let conn else { return }
            let te = Router.timelineEvent(from: event)
            if let data = try? RPCEncoder.notification(method: "event.appended", params: te) {
                conn.sendLine(data)
            }
        }
        conn.subscriptionIDs.insert(id)
        return EventsTailResult(subscriptionId: id)
    }

    private func eventsUntail(_ p: EventsUntailParams, conn: APIConnection) throws -> EventsUntailResult {
        let removed = broadcaster.unsubscribe(p.subscriptionId)
        conn.subscriptionIDs.remove(p.subscriptionId)
        return EventsUntailResult(ok: removed)
    }

    // MARK: - policy

    /// The canonical v2 policy keys (spec 04, D-notify). `holdUntilScanned` is
    /// owner-gated. `notificationThreshold` is deliberately absent: it is
    /// retired, still served on reads, and its writes are rejected with the
    /// migration hint (see `policySet`).
    private static let policyKeys: Set<String> = [
        "scanOnMount", "quarantine", "holdUntilScanned", "scanTimeoutMinutes",
        "clamdSocketPath", "definitionsWarnDays", "retentionDays",
        "notifyUnsafe", "notifyNewDevice"
    ]
    private static let ownerGatedKeys: Set<String> = ["holdUntilScanned"]

    func policyGet() throws -> PolicyObject {
        try migrateLegacyNotificationPolicyIfNeeded()
        var policy = PolicyObject.defaults
        let raw = try store.policyRaw()   // [key: JSON-value bytes]
        for (key, data) in raw {
            let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            apply(key: key, value: value, to: &policy)
        }
        return policy
    }

    /// One-time migration from the retired `notificationThreshold` (D-notify):
    /// any stored threshold means notifications were on, so notifyUnsafe
    /// becomes true; only the old "everything" also wanted new-device pings, so
    /// notifyNewDevice becomes true for it alone. Runs only while NEITHER new
    /// key has ever been written, so an explicit later choice always wins; the
    /// legacy row is kept so old readers still see their threshold.
    private func migrateLegacyNotificationPolicyIfNeeded() throws {
        let raw = try store.policyRaw()
        guard raw["notifyUnsafe"] == nil, raw["notifyNewDevice"] == nil,
              let data = raw["notificationThreshold"],
              let threshold = (try? JSONDecoder().decode(JSONValue.self, from: data))?.stringValue
        else { return }
        try store.setPolicyKey("notifyUnsafe", valueJSON: "true", actor: "migration")
        try store.setPolicyKey("notifyNewDevice",
                               valueJSON: threshold == "everything" ? "true" : "false",
                               actor: "migration")
    }

    func policySet(_ params: JSONValue, actor: String) throws -> PolicyObject {
        guard let object = params.objectValue else {
            throw APIError.invalidParams("policy.set expects a partial policy object.")
        }
        let confirm = object["confirm"]?.boolValue ?? false

        // Validate every provided key BEFORE writing anything (all-or-nothing).
        var toWrite: [(String, JSONValue)] = []
        for (key, value) in object {
            if key == "confirm" { continue }
            if key == "notificationThreshold" {
                throw APIError.invalidParams(
                    "The 'notificationThreshold' setting was replaced. Use 'notifyUnsafe' (notify when a device looks unsafe) and 'notifyNewDevice' (also notify when any new device plugs in) instead.")
            }
            guard Self.policyKeys.contains(key) else {
                throw APIError.invalidParams("Unknown policy key '\(key)'.")
            }
            try validatePolicyValue(key: key, value: value)
            if Self.ownerGatedKeys.contains(key) && !confirm {
                throw APIError.invalidParams("Changing '\(key)' pauses mounts until scanned; resend with confirm:true to apply it.")
            }
            toWrite.append((key, value))
        }

        for (key, value) in toWrite {
            let json = String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "null"
            try store.setPolicyKey(key, valueJSON: json, actor: actor)
        }
        if !toWrite.isEmpty { onPolicyOrTrustChanged?() }
        return try policyGet()
    }

    /// Type-check a policy value against its key's expected type.
    private func validatePolicyValue(key: String, value: JSONValue) throws {
        func requireBool() throws { if value.boolValue == nil { throw APIError.invalidParams("Policy key '\(key)' must be a boolean.") } }
        func requireInt() throws { if value.intValue == nil { throw APIError.invalidParams("Policy key '\(key)' must be an integer.") } }
        switch key {
        case "scanOnMount", "quarantine", "holdUntilScanned",
             "notifyUnsafe", "notifyNewDevice": try requireBool()
        case "scanTimeoutMinutes", "definitionsWarnDays", "retentionDays": try requireInt()
        case "clamdSocketPath":
            if value.stringValue == nil, value != .null {
                throw APIError.invalidParams("Policy key 'clamdSocketPath' must be a string or null.")
            }
        default: break
        }
    }

    private func apply(key: String, value: JSONValue, to policy: inout PolicyObject) {
        switch key {
        case "scanOnMount": if let b = value.boolValue { policy.scanOnMount = b }
        case "quarantine": if let b = value.boolValue { policy.quarantine = b }
        case "holdUntilScanned": if let b = value.boolValue { policy.holdUntilScanned = b }
        case "scanTimeoutMinutes": if let i = value.intValue { policy.scanTimeoutMinutes = i }
        case "definitionsWarnDays": if let i = value.intValue { policy.definitionsWarnDays = i }
        case "retentionDays": if let i = value.intValue { policy.retentionDays = i }
        case "clamdSocketPath": policy.clamdSocketPath = value.stringValue
        case "notifyUnsafe": if let b = value.boolValue { policy.notifyUnsafe = b }
        case "notifyNewDevice": if let b = value.boolValue { policy.notifyNewDevice = b }
        // Retired but still SERVED, so an old reader's stored choice stays visible.
        case "notificationThreshold": if let s = value.stringValue { policy.notificationThreshold = s }
        default: break
        }
    }

    // MARK: - scans

    private func scanStart(_ p: ScanStartParams, actor: String) throws -> ScanStartResult {
        guard resolvedScannerEngine != nil else {
            throw APIError.scannerUnavailable("No malware scanner is installed. Install ClamAV with 'brew install clamav', then retry the scan.")
        }
        // Validate the device up front (a bad deviceId is not_found regardless of
        // whether a volumePath was also supplied).
        if let deviceId = p.deviceId, try store.getDevice(id: deviceId) == nil {
            throw APIError.notFound("No device with id '\(deviceId)'.")
        }
        // Resolve the target volume: an explicit volumePath wins; otherwise map the
        // device to its currently-mounted volume from the timeline.
        let volumePath: String
        if let vp = p.volumePath, !vp.isEmpty {
            volumePath = vp
        } else if let deviceId = p.deviceId {
            guard let resolved = try currentVolumePath(deviceID: deviceId) else {
                throw APIError.invalidParams("Device '\(deviceId)' has no mounted volume to scan; pass 'volumePath' explicitly.")
            }
            volumePath = resolved
        } else {
            throw APIError.invalidParams("scan.start requires either 'deviceId' or 'volumePath'.")
        }

        // Real path (N8b Gap A): drive the ScanOrchestrator. Returns scanId +
        // `running` immediately; the child runs to a terminal state in the
        // background.
        if let scanCoordinator {
            let request = ScanRequest(deviceID: p.deviceId, volumePath: volumePath, startedBy: actor)
            do {
                let started = try scanCoordinator.start(request)
                let state = (try store.getScan(id: started.scanID))?.state ?? "running"
                return ScanStartResult(scanId: started.scanID, state: state)
            } catch let ScanError.scannerUnavailable(installFix) {
                throw APIError.scannerUnavailable(installFix)
            }
        }

        // Fallback (no orchestrator wired — pure routing tests): a placeholder
        // running scan row + scan.started event.
        let scan = try store.insertScan(deviceID: p.deviceId, volumePath: volumePath, engine: "clamdscan", startedBy: actor)
        _ = try store.appendEvent(kind: "scan.started", severity: "info", deviceID: p.deviceId,
                                  actor: actor, summary: "Scan started on \(volumePath).",
                                  detail: "{\"v\":1,\"scanId\":\"\(scan.id)\"}")
        return ScanStartResult(scanId: scan.id, state: scan.state)
    }

    /// The device's currently-mounted volume path, if any: the newest
    /// `volume.mounted` for the device whose volume has not since been unmounted.
    private func currentVolumePath(deviceID: String) throws -> String? {
        let events = try store.timeline(
            deviceID: deviceID, kinds: ["volume.mounted", "volume.unmounted"], limit: 100)
        var unmounted: Set<String> = []   // newer than any mount we still consider
        for e in events {   // newest first
            guard let obj = JSONValue.parse(e.detail).objectValue,
                  let vp = obj["volumePath"]?.stringValue else { continue }
            if e.kind == "volume.unmounted" {
                unmounted.insert(vp)
            } else if e.kind == "volume.mounted", !unmounted.contains(vp) {
                return vp
            }
        }
        return nil
    }

    func scanGet(_ p: ScanGetParams) throws -> ScanDTO {
        guard let s = try store.getScan(id: p.scanId) else {
            throw APIError.notFound("No scan with id '\(p.scanId)'.")
        }
        return Self.scanDTO(from: s)
    }

    func scanCancel(_ p: ScanCancelParams) throws -> ScanDTO {
        guard let s = try store.getScan(id: p.scanId) else {
            throw APIError.notFound("No scan with id '\(p.scanId)'.")
        }
        if s.isTerminal {
            throw APIError.conflict("Scan '\(p.scanId)' already finished as \(s.state); it cannot be canceled.",
                                    extraData: ["state": .string(s.state)])
        }
        // Real path (N8b Gap A): signal the in-flight run's cancel token so the
        // process group is killed, then let its own terminal update land (one
        // scan.finished). Wait briefly for that terminal state to appear.
        if let scanCoordinator, scanCoordinator.cancel(p.scanId) {
            if let terminal = try waitForTerminalScan(id: p.scanId, timeout: 3) {
                return Self.scanDTO(from: terminal)
            }
            // The run did not reach a terminal state in time: cancel the row so the
            // caller still gets an honest `canceled`.
            return Self.scanDTO(from: try store.cancelScan(id: p.scanId))
        }
        // Fallback (no in-flight run — placeholder/seeded row): cancel directly.
        let updated = try store.cancelScan(id: p.scanId)
        return Self.scanDTO(from: updated)
    }

    /// Poll the shared store until the scan reaches a terminal state, or the
    /// timeout elapses. Used by scan.cancel to return the canceled row the
    /// background run writes.
    private func waitForTerminalScan(id: String, timeout: TimeInterval) throws -> StoredScan? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try store.getScan(id: id), s.isTerminal { return s }
            usleep(15_000)
        }
        return nil
    }

    func scansList(_ p: ScansListParams) throws -> ScansListResult {
        let limit = p.limit ?? APIStore.maxPageLimit
        let scans = try store.listScans(deviceID: p.filter?.deviceId, limit: limit, cursor: p.cursor)
        let next = (scans.count == min(max(limit, 1), APIStore.maxPageLimit)) ? scans.last?.id : nil
        return ScansListResult(scans: scans.map(Self.scanSummary(from:)), nextCursor: next)
    }

    // MARK: - quarantine.restore (D6)

    /// The explicit-risk sentence (03) that rides in every successful restore
    /// result so an agent quoting it surfaces the risk to whoever reads it.
    static let restoreRiskSentence = "You are restoring a file ClamAV flagged; only do this if you are certain it is a false positive."

    func quarantineRestore(_ p: QuarantineRestoreParams, actor: String) throws -> QuarantineRestoreResult {
        // confirm:true is MANDATORY — restoring attacker-flagged bytes is a
        // deliberate act. A missing/false confirm is invalid_params, checked before
        // anything else (mirrors 03 and set_policy's mount-hold gate).
        guard p.confirm == true else {
            throw APIError.invalidParams(
                "Restoring a quarantined file is a deliberate act: it moves bytes ClamAV flagged back to their original location. Resend with confirm:true only if you are certain it is a false positive. \(Self.restoreRiskSentence)")
        }

        // The store lookup disambiguates unknown id (no finding row -> not_found)
        // from an already-restored slot (finding row present, files gone ->
        // conflict, decided by the mover below).
        let eventStore = store.eventStore
        guard let finding = try eventStore.quarantineFinding(quarantineId: p.quarantineId) else {
            throw APIError.notFound(
                "No quarantined file with id '\(p.quarantineId)'. Use scan.get to see a scan's quarantine records.")
        }

        let mover = QuarantineRestore(directory: quarantineDirectory)
        let move: RestoreMoveResult
        do {
            move = try mover.restore(quarantineId: p.quarantineId)
        } catch RestoreError.notFound {
            // The finding row exists but the slot is empty: already restored/purged.
            throw APIError.conflict(
                "Quarantine slot '\(p.quarantineId)' is already empty — the file was already restored or purged.",
                extraData: ["state": .string("already_restored"), "quarantineId": .string(p.quarantineId)])
        } catch let RestoreError.destinationExists(path) {
            throw APIError.conflict(
                "Cannot restore '\(p.quarantineId)': a file already exists at the original location \(path); restore never overwrites. Move it aside and retry.",
                extraData: ["state": .string("destination_exists"), "path": .string(path)])
        } catch let RestoreError.unsafeDestination(path) {
            throw APIError.conflict(
                "Refusing to restore '\(p.quarantineId)': the original location \(path) is now a symlink; following it could overwrite an unrelated file.",
                extraData: ["state": .string("unsafe_destination"), "path": .string(path)])
        } catch let RestoreError.moveFailed(reason) {
            throw APIError.conflict(
                "Could not move '\(p.quarantineId)' back to \(finding.filePath): \(reason)",
                extraData: ["state": .string("move_failed")])
        }

        let fileName = (move.originalPath as NSString).lastPathComponent
        let summary = "Restored '\(fileName)' from quarantine (flagged \(finding.signature)) — by \(actor)."
        let detail = Self.restoreDetail(originalPath: move.originalPath, signature: finding.signature,
                                        scanID: finding.scanID, actor: actor)
        let event = try eventStore.appendQuarantineRestoredEvent(
            deviceID: finding.deviceID, actor: actor,
            summary: summary, detail: detail)

        return QuarantineRestoreResult(
            quarantineId: p.quarantineId, scanId: finding.scanID, deviceId: finding.deviceID,
            originalPath: move.originalPath, signature: finding.signature, state: "restored",
            risk: Self.restoreRiskSentence, event: Self.timelineEvent(from: event))
    }

    /// Build the `trust.changed` detail payload. The `note` supplied on the trust
    /// change is included so `trustHistory` (and MCP `oTrustHistory.note`) surface
    /// it per change; a nil note drops the key, so older readers (which tolerate a
    /// missing `note`) stay unaffected. Built via JSONSerialization so a note with
    /// quotes/backslashes cannot break the payload.
    static func trustChangedDetail(from oldTier: String, to newTier: String, note: String?) -> String {
        var obj: [String: Any] = ["v": 1, "from": oldTier, "to": newTier]
        if let note { obj["note"] = note }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"v\":1,\"from\":\"\(oldTier)\",\"to\":\"\(newTier)\"}"
    }

    /// Build the `quarantine.restored` detail payload (bound-safe via
    /// JSONSerialization, so paths/signatures with quotes cannot break the JSON).
    private static func restoreDetail(originalPath: String, signature: String, scanID: String, actor: String) -> String {
        let obj: [String: Any] = [
            "v": 1, "original_path": originalPath, "signature": signature,
            "scan_id": scanID, "actor": actor,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"v\":1}"
    }

    static func scanDTO(from s: StoredScan) -> ScanDTO {
        // Detections become per-file verdicts; quarantined/reported findings become
        // quarantine records (the id is the quarantine-path leaf restore takes).
        let verdicts = s.findings.map {
            ScanVerdictDTO(filePath: $0.filePath, verdict: "infected", signature: $0.signature)
        }
        let quarantine = s.findings.map { f -> QuarantineRecordDTO in
            let qid = f.quarantinePath.map { ($0 as NSString).lastPathComponent } ?? f.filePath
            return QuarantineRecordDTO(
                quarantineId: qid, filePath: f.filePath, signature: f.signature,
                restored: false, containment: f.action)
        }
        return ScanDTO(
            scanId: s.id, deviceId: s.deviceID, volumePath: s.volumePath, engine: s.engine,
            defsAgeDays: s.defsAgeDays, state: s.state, progress: nil, startedAt: s.startedAt,
            finishedAt: s.finishedAt, filesScanned: s.filesScanned, startedBy: s.startedBy,
            verdicts: verdicts, quarantine: quarantine, reason: Self.scanReason(state: s.state))
    }

    /// A non-blank reason sentence for the non-clean terminal states (5c/5f); nil
    /// for running/clean/infected where the state word already says it.
    static func scanReason(state: String) -> String? {
        switch state {
        case "failed": return "The scan did not finish."
        case "skipped": return "The scan was skipped."
        case "canceled": return "The scan was canceled."
        default: return nil
        }
    }

    static func scanSummary(from s: StoredScan) -> ScanSummary {
        ScanSummary(scanId: s.id, deviceId: s.deviceID, volumePath: s.volumePath, engine: s.engine,
                    state: s.state, startedAt: s.startedAt, finishedAt: s.finishedAt,
                    filesScanned: s.filesScanned, reason: Self.scanReason(state: s.state))
    }

    /// Build a full DeviceRecord from an already-fetched StoredDevice, including
    /// the derived trust history, topology, and isStorage flag (03/06).
    func deviceRecord(from d: StoredDevice) throws -> DeviceRecord {
        let score = try store.latestScore(deviceID: d.id).map { ScoreBrief(value: $0.score, confidence: $0.confidence) }
        let scanning = try store.hasRunningScan(deviceID: d.id)
        return DeviceRecord(
            deviceId: d.id, name: d.displayName, present: d.present, firstSeen: d.firstSeenAt,
            lastSeen: d.lastSeenAt, vidPid: Self.vidPid(d.vid, d.pid), serial: d.serial,
            identityBasis: d.identityBasis, trust: d.trustTier, trustNote: d.trustNote,
            trustSetBy: d.trustSetBy, trustSetAt: d.trustSetAt,
            interfaces: d.interfaces.map { InterfaceDTO(seq: $0.seq, usbClass: $0.usbClass, usbSubclass: $0.usbSubclass, usbProtocol: $0.usbProtocol, role: $0.role) },
            score: score, eventCount: try store.eventCount(deviceID: d.id),
            scanCount: try store.scanCount(deviceID: d.id),
            trustHistory: try trustHistory(deviceID: d.id),
            topology: try topology(deviceID: d.id),
            isStorage: Self.isStorage(d.interfaces),
            scanning: scanning,
            lastScan: try lastScanBrief(deviceID: d.id),
            safetyStatus: try safetyStatus(for: d, scanning: scanning, context: safetyContext()))
    }

    /// A device is "storage" if any interface enumerated as mass storage (06 role
    /// word 'storage'); drives the inspector's Eject affordance.
    static func isStorage(_ interfaces: [StoredInterface]) -> Bool {
        interfaces.contains { $0.role == "storage" || $0.usbClass == 0x08 }
    }

    /// The device's trust history: its `trust.changed` events, newest first, each
    /// resolved to (tier moved-to, actor, at, note). 06: trust history is an event
    /// query, not a table.
    private func trustHistory(deviceID: String) throws -> [TrustHistoryEntry] {
        let events = try store.timeline(deviceID: deviceID, kinds: ["trust.changed"], limit: 100)
        return events.map { e in
            let obj = JSONValue.parse(e.detail).objectValue
            let tier = obj?["to"]?.stringValue ?? "none"
            let note = obj?["note"]?.stringValue
            return TrustHistoryEntry(tier: tier, actor: e.actor, at: e.at, note: note)
        }
    }

    /// Topology (port + hub path) from the port path the collector recorded on the
    /// device's most recent `device.attached` event. Nil when we never recorded one
    /// (no schema column exists for it — 06 is frozen).
    private func topology(deviceID: String) throws -> TopologyDTO? {
        let events = try store.timeline(deviceID: deviceID, kinds: ["device.attached"], limit: 1)
        guard let detail = events.first.map({ JSONValue.parse($0.detail) }),
              let port = detail.objectValue?["portPath"]?.stringValue, !port.isEmpty else {
            return nil
        }
        // "20-2.4" -> hops ["2","4"] (everything after the bus separator).
        let hops = port.split(separator: "-").dropFirst().joined(separator: "-")
            .split(separator: ".").map(String.init)
        return TopologyDTO(port: port, hubPath: hops)
    }

    static func timelineEvent(from e: StoredEvent) -> TimelineEvent {
        TimelineEvent(eventId: e.id, at: e.at, kind: e.kind, severity: e.severity,
                      deviceId: e.deviceID, summary: e.summary, actor: e.actor,
                      detail: e.detail.isEmpty ? nil : e.detail)
    }

    static func vidPid(_ vid: Int, _ pid: Int) -> String { String(format: "%04x:%04x", vid, pid) }

    /// ISO-8601 UTC millis (PlugsightCore's ISO8601Millis is internal to that
    /// module, so the Daemon keeps its own formatter).
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    static func nowISO() -> String { isoFormatter.string(from: Date()) }

    // MARK: - Helpers

    /// Derive the timeline actor string from clientInfo (02): `ui`, `mcp:<name>`,
    /// or `cli`.
    static func actor(from info: ClientInfo) -> String {
        switch info.kind {
        case "mcp": return "mcp:\(info.name)"
        case "ui": return "ui"
        case "cli": return "cli"
        default: return info.kind.isEmpty ? "cli" : info.kind
        }
    }

    /// Constant-time string comparison so token checks do not leak length/prefix
    /// via timing.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = ab.count ^ bb.count
        let n = max(ab.count, bb.count)
        for i in 0..<n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }
}
