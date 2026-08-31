// DaemonCore.swift  (N8)
//
// The testable daemon assembly (docs/spec/07 N8): ONE EventStore -> the API
// server (real UDS socket + token) -> a DeviceEventSource (production: the
// composite IOKit/HID/DiskArbitration source; tests: FakeDeviceEventSource) ->
// the analyzer loop:
//   - `.attached`: upsert the device, append `device.attached`, run the
//     mismatch rules (allowlist first, 05), append `mismatch.detected` /
//     `mismatch.allowlisted`, and alert per the device's trust tier
//     (AlertDecision).
//   - the same stream feeds the pure ScorerEngine; its findings are PERSISTED
//     here (step C): score_snapshots row + `hid.typing_burst` +
//     `score.changed`, re-deciding severity with the device's REAL trust tier
//     and escalating the active alert as the T1 story describes.
//   - `.volumeMounted` wires the ScanOrchestrator (a missing engine degrades
//     honestly to a `skipped` scan).
// Startup runs the L10 monitoring-gap check; every append fans out over
// `event.appended` through the store's observer bus (N8-A).
//
// `main.swift` stays thin: it parses boot options, probes capabilities, builds
// the sources, and calls this type.

import Foundation
import PlugsightCore

public final class DaemonCore: @unchecked Sendable {

    public let store: EventStore
    public let server: APIServer

    private let source: DeviceEventSource
    private let capabilities: Capabilities
    private let tuning: Tuning
    private let allowlist: Allowlist
    private let scanOrchestrator: ScanOrchestrator?
    private let scanConfig: ScanConfig?
    private let daemonVersion: String
    private let clock: () -> Date
    private let bootTime: () -> Date

    private let scorer: ScorerEngine

    /// Analyzer session state (touched only on the analyzer task + start/stop,
    /// guarded by `stateLock` for the API-thread reads that never happen today
    /// but cost nothing to make safe).
    private let stateLock = NSLock()
    private var deviceIDByKey: [String: String] = [:]
    /// First-enumeration facts per device key, for R5/R6 (interface count,
    /// serial) within this source session.
    private var firstEnumeration: [String: (interfaceCount: Int, serial: String?)] = [:]
    private var analyzerTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    /// - Parameters:
    ///   - store: the ONE store every component writes through (N8-A).
    ///   - source: the collector seam. Production wires the composite hardware
    ///     source; integration tests inject a `FakeDeviceEventSource`.
    ///   - capabilities: degraded-capability flags as probed at boot (D).
    ///   - scanOrchestrator/scanConfig: when present, volume mounts trigger a
    ///     scan; an unavailable engine degrades honestly (scan.skipped).
    ///   - clock/bootTime: injectable for the gap-detection tests (E).
    public init(
        store: EventStore,
        source: DeviceEventSource,
        stateDirectory: String,
        daemonVersion: String = "0.1.0",
        capabilities: Capabilities,
        tuning: Tuning = .default,
        allowlist: Allowlist? = nil,
        quarantineDirectory: String? = nil,
        scanOrchestrator: ScanOrchestrator? = nil,
        scanConfig: ScanConfig? = nil,
        clamavResolver: (@Sendable () -> String?)? = nil,
        definitionsAgeResolver: (@Sendable () -> Int?)? = nil,
        scannerInstaller: ScannerInstaller? = nil,
        clock: @escaping () -> Date = Date.init,
        bootTime: @escaping () -> Date = DaemonCore.systemBootTime
    ) {
        self.store = store
        self.source = source
        self.capabilities = capabilities
        self.tuning = tuning
        self.allowlist = allowlist ?? (try? Allowlist.loadShipped()) ?? Allowlist(patterns: [])
        self.scanOrchestrator = scanOrchestrator
        self.scanConfig = scanConfig
        self.daemonVersion = daemonVersion
        self.clock = clock
        self.bootTime = bootTime
        self.scorer = ScorerEngine(tuning: tuning, clock: clock)
        self.server = APIServer(
            store: store,
            stateDirectory: stateDirectory,
            daemonVersion: daemonVersion,
            capabilities: capabilities,
            quarantineDirectory: quarantineDirectory,
            // Wire the API `scan.start` to drive the same orchestrator the mount
            // path uses (N8b Gap A), so an agent/UI scan performs a real scan.
            scanOrchestrator: scanOrchestrator,
            // Fresh scanner availability on status.get: an engine installed while
            // the daemon runs is seen without a restart (onboarding scanner step).
            clamavResolver: clamavResolver,
            // The REAL definitions age on status.get, and the one-click ClamAV
            // installer scanner.install drives (onboarding scanner step).
            definitionsAgeResolver: definitionsAgeResolver,
            scannerInstaller: scannerInstaller
        )
    }

    /// The machine's boot time (kern.boottime), for the L10 gap check: if the
    /// machine was up while the daemon was not, that absence is a monitoring gap.
    public static func systemBootTime() -> Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let rc = sysctl(&mib, 2, &tv, &size, nil, 0)
        guard rc == 0 else { return Date.distantPast }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    // MARK: - Lifecycle

    /// Boot: monitoring-gap check (L10), `daemon.started`, API server up.
    public func start() throws {
        stateLock.lock()
        let alreadyStarted = started
        started = true
        stateLock.unlock()
        guard !alreadyStarted else { return }

        let now = clock()
        try detectMonitoringGap(now: now)
        try store.appendEvent(
            kind: "daemon.started", severity: "info",
            summary: "Plugsight daemon \(daemonVersion) started.",
            detail: "{\"v\":1,\"version\":\"\(daemonVersion)\"}",
            at: now
        )
        try server.start()
    }

    /// Start the collector source and the analyzer loop consuming it. Split
    /// from `start()` so tests (and any late subscriber) can attach an
    /// `events.tail` before the first collector event flows.
    public func startEventFlow() {
        do {
            try source.start()
        } catch {
            FileHandle.standardError.write(Data("plugsightd: collector source failed to start: \(error)\n".utf8))
        }
        let task = Task { [self] in
            for await event in source.events {
                handle(event)
            }
            // Source stream finished: close every open scorer epoch honestly.
            persist(findings: scorer.finish())
        }
        stateLock.lock()
        analyzerTask = task
        stateLock.unlock()
    }

    /// Await the analyzer loop draining a finished source stream (tests).
    public func waitForEventFlowCompletion() async {
        await currentAnalyzerTask()?.value
    }

    private func currentAnalyzerTask() -> Task<Void, Never>? {
        stateLock.lock(); defer { stateLock.unlock() }
        return analyzerTask
    }

    /// Clean shutdown: `daemon.stopped`, stop the source and the server.
    /// Idempotent — the second call is a no-op.
    public func stop() {
        stateLock.lock()
        let alreadyStopped = stopped
        stopped = true
        stateLock.unlock()
        guard !alreadyStopped else { return }

        source.stop()
        try? store.appendEvent(
            kind: "daemon.stopped", severity: "info",
            summary: "Plugsight daemon stopped.",
            at: clock()
        )
        server.stop()
    }

    // MARK: - Monitoring-gap detection (E, L10)

    /// If the last shutdown was unclean (a `daemon.started` with no
    /// `daemon.stopped` after it) and the machine was up across the gap
    /// (booted BEFORE the last recorded event, i.e. no reboot since), append a
    /// `monitoring.gap` event covering last-event -> now. Absence of data is
    /// data (04's 7a): the timeline must say when nobody was watching.
    private func detectMonitoringGap(now: Date) throws {
        let lastStarted = try store.listEvents(filter: EventFilter(kind: "daemon.started"), limit: 1).first
        guard let lastStarted else { return }   // first boot ever: nothing missed

        let lastStopped = try store.listEvents(filter: EventFilter(kind: "daemon.stopped"), limit: 1).first
        let cleanShutdown = lastStopped.map { $0.id > lastStarted.id } ?? false
        guard !cleanShutdown else { return }

        guard let lastEvent = try store.listEvents(limit: 1).first,
              let lastEventDate = Self.parseISO(lastEvent.at) else { return }
        // Machine up across the gap: it booted before the last event and has
        // not rebooted since. A reboot after the last event means the machine
        // (and every USB port on it) was down, not just the daemon.
        guard bootTime() < lastEventDate, lastEventDate < now else { return }

        let from = lastEvent.at
        let to = Self.isoString(now)
        try store.appendEvent(
            kind: "monitoring.gap", severity: "notice",
            summary: "Monitoring was off between \(from) and \(to).",
            detail: Self.jsonObject(["v": 1, "from": from, "to": to]),
            at: now
        )
    }

    // MARK: - Analyzer loop

    private func handle(_ event: CollectorEvent) {
        do {
            switch event {
            case .attached(let device):
                try handleAttached(device)
                persist(findings: scorer.ingest(event))

            case .detached(let deviceKey, let at):
                persist(findings: scorer.ingest(event))
                try handleDetached(deviceKey: deviceKey, at: at)

            case .inputActivity:
                persist(findings: scorer.ingest(event))

            case .interfacesRead(let deviceKey, let interfaces):
                try handleInterfacesRead(deviceKey: deviceKey, interfaces: interfaces)

            case .volumeMounted(let volume):
                try handleVolumeMounted(volume)

            case .volumeUnmounted(let deviceKey, let volumePath, let at):
                let deviceID = lookupDeviceID(deviceKey)
                try store.appendEvent(
                    kind: "volume.unmounted", severity: "info", deviceID: deviceID,
                    summary: "Volume \(volumeLeaf(volumePath)) unmounted.",
                    detail: Self.jsonObject(["v": 1, "volumePath": volumePath]),
                    at: at
                )
            }
        } catch {
            FileHandle.standardError.write(Data("plugsightd: analyzer error: \(error)\n".utf8))
        }
    }

    private func handleAttached(_ device: DeviceDescriptor) throws {
        let now = clock()
        let upsert = try store.upsertDevice(from: device, at: now)
        stateLock.lock()
        deviceIDByKey[device.deviceKey] = upsert.deviceID
        let previous = firstEnumeration[device.deviceKey]
        if previous == nil {
            firstEnumeration[device.deviceKey] = (device.interfaces.count, device.serial)
        }
        stateLock.unlock()

        let stored = try store.getDevice(id: upsert.deviceID)
        let displayName = stored?.displayName ?? "USB device"
        let roles = stored.map { $0.interfaces.map(\.role).joined(separator: ", ") } ?? ""
        try store.appendEvent(
            kind: "device.attached", severity: "info", deviceID: upsert.deviceID,
            summary: "\(displayName) plugged in." + (roles.isEmpty ? "" : " Presents as: \(roles)."),
            detail: Self.jsonObject([
                "v": 1, "vidPid": String(format: "%04x:%04x", device.vid, device.pid),
                "isNew": upsert.isNew,
                // Port/hub path (for devices.get topology). Empty string when the
                // source could not derive one; devices.get treats that as unknown.
                "portPath": device.portPath ?? "",
            ]),
            at: now
        )

        // Mismatch rules (allowlist checked first, 05). R5/R6 history facts
        // come from this session's first enumeration of the same device key.
        let input = MismatchInput(
            vid: device.vid, pid: device.pid,
            vendorName: device.vendorName, productName: device.productName,
            interfaces: device.interfaces,
            previousInterfaceCount: previous.map(\.interfaceCount),
            serialChangedAcrossAttaches: previous.map { $0.serial != device.serial } ?? false
        )
        let findings = MismatchRules.evaluate(input, allowlist: allowlist)
        try process(findings: findings, deviceID: upsert.deviceID, displayName: displayName, at: now)
    }

    private func handleDetached(deviceKey: String, at: Date) throws {
        guard let deviceID = lookupDeviceID(deviceKey) else { return }
        try store.markDetached(deviceID: deviceID, at: at)
        let displayName = (try? store.getDevice(id: deviceID))??.displayName ?? "USB device"
        try store.appendEvent(
            kind: "device.detached", severity: "info", deviceID: deviceID,
            summary: "\(displayName) unplugged.",
            at: at
        )
    }

    private func handleInterfacesRead(deviceKey: String, interfaces: [InterfaceDescriptor]) throws {
        guard let deviceID = lookupDeviceID(deviceKey) else { return }
        stateLock.lock()
        let previous = firstEnumeration[deviceKey]
        stateLock.unlock()
        // Late interfaces (R5): the device now shows MORE interfaces than its
        // first enumeration this session.
        guard let previous, interfaces.count > previous.interfaceCount else { return }
        let now = clock()
        let displayName = (try? store.getDevice(id: deviceID))??.displayName ?? "USB device"
        let input = MismatchInput(
            vid: 0, pid: 0, vendorName: nil, productName: nil,
            interfaces: interfaces,
            previousInterfaceCount: previous.interfaceCount
        )
        // Only the history findings matter here; composite-shape findings were
        // already evaluated (and alerted) at attach.
        let findings = MismatchRules.evaluate(input, allowlist: allowlist)
            .filter { $0.rule == .r5LateInterface }
        try process(findings: findings, deviceID: deviceID, displayName: displayName, at: now)
    }

    private func handleVolumeMounted(_ volume: VolumeDescriptor) throws {
        let deviceID = lookupDeviceID(volume.deviceKey)
        let name = volume.volumeName ?? volumeLeaf(volume.volumePath)
        try store.appendEvent(
            kind: "volume.mounted", severity: "info", deviceID: deviceID,
            summary: "Volume \(name) mounted at \(volume.volumePath).",
            detail: Self.jsonObject([
                "v": 1, "volumePath": volume.volumePath,
                "totalBytes": volume.totalBytes,
            ]),
            at: clock()
        )

        guard let scanOrchestrator, let scanConfig else { return }

        // Honor policy `scanOnMount` (05): only scan on mount when the operator
        // enabled it AND the device is not `trusted`. Absent policy rows fall
        // back to the v1 defaults (scanOnMount = false), so nothing scans until
        // it is explicitly turned on.
        let policyRaw = (try? APIStore(store: store).policyRaw()) ?? [:]
        guard Self.scanOnMountEnabled(policyRaw), !isTrusted(deviceID: deviceID) else { return }

        // Resolve the config from the LIVE policy rows at scan time (N8b Gap B),
        // so a `policy.set` (quarantine, scanTimeoutMinutes, …) takes effect for
        // subsequent mount scans. The injected `scanConfig` supplies the base
        // (quarantine directory + defaults when no rows are set).
        let liveConfig = ScanConfigResolver.resolve(base: scanConfig, policyRaw: policyRaw)
        let request = ScanRequest(deviceID: deviceID, volumePath: volume.volumePath, startedBy: "system")

        // Open the scan row synchronously (fast: engine resolve + row insert),
        // then drive the BLOCKING child process on a background thread so the
        // analyzer loop keeps handling attach/detach/HID events while a scan
        // runs — mirrors the API path (ScanCoordinator). A missing engine still
        // records a `skipped` scan here (with the install fix in its summary).
        let started: StartedScan
        do {
            started = try scanOrchestrator.begin(request, config: liveConfig)
        } catch ScanError.scannerUnavailable {
            return   // recorded honestly as a skipped scan; monitoring continues degraded
        }
        Thread.detachNewThread { [scanOrchestrator] in
            _ = try? scanOrchestrator.run(started, request: request, config: liveConfig)
        }
    }

    /// True when policy `scanOnMount` is enabled. An absent/unparsable row falls
    /// back to the v1 default (false), matching `ScanConfigResolver`'s tolerance.
    private static func scanOnMountEnabled(_ policyRaw: [String: Data]) -> Bool {
        guard let data = policyRaw["scanOnMount"],
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let on = value.boolValue else {
            return PolicyObject.defaults.scanOnMount
        }
        return on
    }

    /// A device the operator marked `trusted` is exempt from mount scanning (05).
    /// An unmapped device (nil id) is not trusted.
    private func isTrusted(deviceID: String?) -> Bool {
        guard let deviceID else { return false }
        return trustTier(deviceID: deviceID) == .trusted
    }

    // MARK: - Mismatch findings -> events + alerts

    /// 06 alert-rule vocabulary for the mismatch rules.
    private static let ruleLabels: [MismatchRule: String] = [
        .r1HiddenKeyboard: "R1", .r2HiddenNetwork: "R2", .r3KeyboardPlusNetwork: "R3",
        .r4KeyboardPlusStorage: "R4", .r5LateInterface: "R5", .r6DescriptorAnomaly: "R6",
    ]

    private func process(
        findings: [MismatchFinding], deviceID: String, displayName: String, at now: Date
    ) throws {
        guard !findings.isEmpty else { return }
        let tier = trustTier(deviceID: deviceID)

        for finding in findings {
            if finding.rule == .allowlisted {
                try store.appendEvent(
                    kind: "mismatch.allowlisted", severity: "info", deviceID: deviceID,
                    summary: "Composite device matching the \(finding.allowlistedPattern ?? "allowlisted") shape.",
                    detail: Self.jsonObject(["v": 1, "pattern": finding.allowlistedPattern]),
                    at: now
                )
                continue
            }

            let summary = "\(displayName): \(finding.detail)."
            try store.appendEvent(
                kind: "mismatch.detected", severity: finding.severity.rawValue,
                deviceID: deviceID,
                summary: summary,
                detail: Self.jsonObject([
                    "v": 1, "rule": finding.rule.rawValue, "severity": finding.severity.rawValue,
                ]),
                at: now
            )

            // Notify decision from the device's REAL trust tier (05): every
            // event is recorded above regardless; only alerting is gated.
            let decision = AlertDecision.forSeverity(finding.severity, tier: tier)
            guard decision.shouldAlert, let severity = decision.effectiveSeverity else { continue }
            let rule = Self.ruleLabels[finding.rule] ?? finding.rule.rawValue
            _ = try store.raiseAlert(
                rule: rule,
                severity: severity.rawValue,
                deviceID: deviceID,
                summary: summary,
                why: "Rule \(rule) matched: \(finding.detail). Interface facts are quoted from the device's own descriptors.",
                detail: Self.jsonObject(["v": 1, "rule": finding.rule.rawValue]),
                at: now
            )
        }
    }

    // MARK: - Scorer findings -> persistence (step C)

    private func persist(findings: [ScorerFinding]) {
        for finding in findings {
            do {
                try persist(finding)
            } catch {
                FileHandle.standardError.write(Data("plugsightd: scorer persistence error: \(error)\n".utf8))
            }
        }
    }

    private func persist(_ finding: ScorerFinding) throws {
        guard let deviceID = lookupDeviceID(finding.deviceKey) else { return }

        switch finding.kind {
        case "hid.typing_burst":
            try store.appendEvent(
                kind: "hid.typing_burst", severity: "notice", deviceID: deviceID,
                summary: finding.summary,
                detail: Self.jsonObject([
                    "v": 1,
                    "keystrokes": finding.burst.keystrokes,
                    "firstKeyLatencyMs": finding.burst.firstKeyLatencyMs,
                    "meanIntervalMs": finding.burst.meanIntervalMs,
                    "stddevIntervalMs": finding.burst.stddevIntervalMs,
                ]),
                at: finding.at
            )

        case "score.changed":
            guard let score = finding.score else { return }
            // Persist the snapshot (03's signal shape, decodable by score.get).
            try store.insertScoreSnapshot(
                deviceID: deviceID,
                score: score.score,
                confidence: score.confidence.rawValue,
                signals: Self.signalsJSON(score: score, burst: finding.burst),
                at: finding.at
            )

            // RE-DECIDE with the device's REAL trust tier (N6 used the default).
            let tier = trustTier(deviceID: deviceID)
            let decision = AlertDecision.forScore(
                score.score, confidence: score.confidence, tier: tier, tuning: tuning
            )
            let eventSeverity = decision.effectiveSeverity?.rawValue ?? DetectionSeverity.notice.rawValue
            try store.appendEvent(
                kind: "score.changed", severity: eventSeverity, deviceID: deviceID,
                summary: finding.summary,
                detail: Self.jsonObject([
                    "v": 1, "score": score.score, "confidence": score.confidence.rawValue,
                ]),
                at: finding.at
            )

            guard decision.shouldAlert, let severity = decision.effectiveSeverity else { return }
            let summary = "Behavior score \(score.score) (\(score.confidence.rawValue) confidence): "
                + finding.summary
            if let active = try store.activeAlert(deviceID: deviceID) {
                // Escalate the SAME alert the mismatch raised (T1): severity
                // only ever rises.
                let existing = DetectionSeverity(rawValue: active.severity) ?? .notice
                let escalated = max(existing, severity)
                try store.escalateAlert(
                    id: active.id,
                    toSeverity: escalated.rawValue,
                    deviceID: deviceID,
                    summary: "Alert escalated: behavior score \(score.score) (\(score.confidence.rawValue) confidence).",
                    detail: Self.jsonObject(["v": 1, "score": score.score]),
                    at: finding.at
                )
            } else {
                _ = try store.raiseAlert(
                    rule: "behavioral_score",
                    severity: severity.rawValue,
                    deviceID: deviceID,
                    summary: summary,
                    why: "Behavioral scoring is probabilistic and a patient attacker can evade it. "
                        + "This burst scored \(score.score) with \(score.confidence.rawValue) confidence.",
                    detail: Self.jsonObject(["v": 1, "score": score.score]),
                    at: finding.at
                )
            }

        default:
            break
        }
    }

    /// Render the four unit signals in 03's decodable ScoreSignal shape.
    private static func signalsJSON(score: BehavioralScore, burst: BurstStats) -> String {
        func verdict(_ value: Double) -> String { value > 0.5 ? "suspicious" : "normal" }
        let signals: [[String: Any]] = [
            ["id": "plug_to_type_latency",
             "observed": "first keystroke \(burst.firstKeyLatencyMs) ms after plug-in",
             "verdict": verdict(score.signals.latency),
             "weight": score.signals.latency],
            ["id": "inter_key_timing",
             "observed": String(format: "mean %.0f ms, stddev %.0f ms over %d keys",
                                burst.meanIntervalMs, burst.stddevIntervalMs, burst.keystrokes),
             "verdict": verdict(score.signals.timing),
             "weight": score.signals.timing],
            ["id": "redundant_keyboard",
             "observed": burst.redundantKeyboard
                ? "another keyboard was active when this one attached" : "no other keyboard active",
             "verdict": verdict(score.signals.redundant),
             "weight": score.signals.redundant],
            ["id": "descriptor_oddity",
             "observed": burst.descriptorOddity
                ? "descriptor matches common injector boilerplate" : "descriptor unremarkable",
             "verdict": verdict(score.signals.oddity),
             "weight": score.signals.oddity],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: signals, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[]"
    }

    // MARK: - Helpers

    private func lookupDeviceID(_ deviceKey: String) -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return deviceIDByKey[deviceKey]
    }

    private func trustTier(deviceID: String) -> TrustTier {
        guard let device = try? store.getDevice(id: deviceID) else { return .none }
        return TrustTier(rawValue: device.trustTier) ?? .none
    }

    private func volumeLeaf(_ path: String) -> String {
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }

    /// JSON via JSONSerialization so quotes/backslashes in facts can never
    /// break the payload (mirrors the store's no-interpolation discipline).
    /// Nil values are dropped.
    private static func jsonObject(_ object: [String: Any?]) -> String {
        var cleaned: [String: Any] = [:]
        for (key, value) in object {
            if let value { cleaned[key] = value }
        }
        if let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"v\":1}"
    }

    // ISO-8601 UTC millis (PlugsightCore's ISO8601Millis is internal there).
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func isoString(_ date: Date) -> String { isoFormatter.string(from: date) }

    static func parseISO(_ string: String) -> Date? {
        if let d = isoFormatter.date(from: string) { return d }
        // Tolerate second-precision timestamps.
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}
