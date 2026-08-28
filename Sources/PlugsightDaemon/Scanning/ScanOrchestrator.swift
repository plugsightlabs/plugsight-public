// ScanOrchestrator.swift
//
// Tie the ClamAV pieces together for one scan (docs/spec/05): resolve the engine,
// record the scan, run the child process under timeout/cancel, parse the verdict,
// contain findings (or honestly report-only), and persist the lifecycle + alerts
// through EventStore+Scans. It is deliberately thin — every decision it makes is
// already unit-tested in the components; this is the wiring and the store side.
//
// Honesty rules enforced here:
//   - A missing engine does NOT silently no-op: it records a `skipped` scan and
//     throws `scannerUnavailable` carrying the install fix (surfaced by callers).
//   - exit 2 / timeout render `failed`, never `clean` (ScanOutputParser).
//   - A finding that could not be contained is recorded as `reported_only` and
//     the alert says exactly why (read-only volume, unsafe symlink, or policy).

import Foundation
import PlugsightCore

/// One scan request (from a mount, a manual trigger, etc.).
public struct ScanRequest: Equatable, Sendable {
    public let deviceID: String?
    public let volumePath: String
    public let startedBy: String

    public init(deviceID: String?, volumePath: String, startedBy: String) {
        self.deviceID = deviceID
        self.volumePath = volumePath
        self.startedBy = startedBy
    }
}

/// Policy-derived knobs for a scan.
public struct ScanConfig: Equatable, Sendable {
    /// Hard timeout in seconds (policy `scanTimeoutMinutes` * 60).
    public let timeout: TimeInterval
    /// Whether findings are moved to quarantine (policy `quarantine`).
    public let quarantineEnabled: Bool
    /// Definitions older than this warn (policy `definitionsWarnDays`).
    public let definitionsWarnDays: Int
    /// Where quarantined files live (02).
    public let quarantineDirectory: String

    public init(timeout: TimeInterval, quarantineEnabled: Bool,
                definitionsWarnDays: Int, quarantineDirectory: String) {
        self.timeout = timeout
        self.quarantineEnabled = quarantineEnabled
        self.definitionsWarnDays = definitionsWarnDays
        self.quarantineDirectory = quarantineDirectory
    }

    /// A config built from the v1 policy DEFAULTS (`PolicyObject.defaults`) plus a
    /// quarantine directory. `ScanConfigResolver` overlays the live policy rows on
    /// top of this so an operator's `policy.set` takes effect at scan time.
    public static func defaults(quarantineDirectory: String) -> ScanConfig {
        let d = PolicyObject.defaults
        return ScanConfig(
            timeout: TimeInterval(max(1, d.scanTimeoutMinutes) * 60),
            quarantineEnabled: d.quarantine,
            definitionsWarnDays: d.definitionsWarnDays,
            quarantineDirectory: quarantineDirectory
        )
    }
}

/// Errors surfaced to callers (and, for the missing engine, to Settings and to
/// any scan-attempt error) with the exact remediation copy.
public enum ScanError: Error, Equatable {
    case scannerUnavailable(installFix: String)
}

/// What a scan run produced.
public struct ScanRunOutcome: Equatable, Sendable {
    public let scanID: String
    public let state: ScanState
    public let findingActions: [FindingAction]
}

/// A scan whose row is open (`running`, `scan.started` appended) and whose engine
/// is resolved — everything `run` needs to drive it to a terminal state. Produced
/// by `begin`, so an async caller (the API `scan.start`) can return the scanId and
/// `running` immediately, then drive the child process in the background.
public struct StartedScan: Sendable {
    public let scanID: String
    let executable: String
    let engineName: String
    let extraArgs: [String]
    let defsNotice: String?
}

public final class ScanOrchestrator {

    private let store: EventStore
    private let discovery: EngineDiscovery
    private let runner: ScanProcessRunner
    private let definitions: DefinitionsAge?
    private let clock: () -> Date

    public init(
        store: EventStore,
        discovery: EngineDiscovery,
        runner: ScanProcessRunner,
        definitions: DefinitionsAge?,
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.discovery = discovery
        self.runner = runner
        self.definitions = definitions
        self.clock = clock
    }

    /// Run one scan to completion (synchronous). Throws `scannerUnavailable`
    /// (after recording a `skipped` scan) when no engine is present. Used by the
    /// mount-triggered path, which drives the scan inline on the analyzer loop.
    @discardableResult
    public func scan(_ request: ScanRequest, config: ScanConfig, cancel: CancelToken? = nil) throws -> ScanRunOutcome {
        let started = try begin(request, config: config)
        return try run(started, request: request, config: config, cancel: cancel)
    }

    /// Phase 1: resolve the engine (or record a `skipped` scan and throw
    /// `scannerUnavailable`), record the definitions age, and open the `running`
    /// scan row with its `scan.started` event. Returns immediately with the
    /// scanId, so an async caller can report `running` before the child runs.
    public func begin(_ request: ScanRequest, config: ScanConfig, at instant: Date? = nil) throws -> StartedScan {
        let now = instant ?? clock()

        // 1. Resolve the engine, or record a skipped scan and surface the fix.
        let engine = discovery.resolve()
        let executable: String
        let engineName: String
        var extraArgs: [String] = []
        switch engine {
        case let .clamdscan(exe, socket):
            executable = exe
            engineName = "clamdscan"
            extraArgs = ["--fdpass", "--no-summary", "--socket=\(socket)"]
        case let .clamscan(exe):
            executable = exe
            engineName = "clamscan"
            extraArgs = ["--recursive", "--no-summary"]
        case let .unavailable(installFix):
            _ = try store.recordSkippedScan(
                deviceID: request.deviceID, volumePath: request.volumePath,
                engine: "none", startedBy: request.startedBy,
                skippedSummary: "Scan skipped — \(installFix)", at: now
            )
            throw ScanError.scannerUnavailable(installFix: installFix)
        }

        // 2. Definitions age (recorded on the scan row; a stale notice is folded
        //    into the finished summary).
        let defsAge = definitions?.ageInDays(now: now)
        let defsNotice = definitions?.notice(now: now, warnDays: config.definitionsWarnDays)

        // 3. Open the scan record.
        let scanID = try store.createScan(
            deviceID: request.deviceID, volumePath: request.volumePath,
            engine: engineName, defsAgeDays: defsAge, startedBy: request.startedBy,
            startedSummary: "Scanning “\(volumeName(request.volumePath))” with \(engineName)…", at: now
        )

        return StartedScan(scanID: scanID, executable: executable,
                           engineName: engineName, extraArgs: extraArgs, defsNotice: defsNotice)
    }

    /// Phase 2: run the child process to a terminal state, contain any findings,
    /// and close the scan row with an honest `scan.finished` summary. Safe to call
    /// on a background thread; cancellation is honored via `cancel`.
    @discardableResult
    public func run(_ started: StartedScan, request: ScanRequest, config: ScanConfig, cancel: CancelToken? = nil) throws -> ScanRunOutcome {
        // Run the child process (volume path is the LAST argument).
        let result = runner.run(
            executable: started.executable, arguments: started.extraArgs + [request.volumePath],
            timeout: config.timeout, cancel: cancel
        )
        let report = ScanOutputParser.report(outcome: result.outcome, stdout: result.stdout)

        // Handle findings.
        var actions: [FindingAction] = []
        let now = clock()
        if report.state == .infected {
            for finding in report.findings {
                let action = try contain(finding: finding, request: request, scanID: started.scanID, config: config, now: now)
                actions.append(action)
            }
        }

        // Close the scan record with an honest finished summary.
        let finishedAt = clock()
        try store.updateScan(
            id: started.scanID, state: report.state.rawValue,
            filesScanned: report.filesScanned,
            finishedSummary: finishedSummary(report: report, volume: request.volumePath, defsNotice: started.defsNotice),
            deviceID: request.deviceID, at: finishedAt
        )

        return ScanRunOutcome(scanID: started.scanID, state: report.state, findingActions: actions)
    }

    // MARK: - Findings

    private func contain(
        finding: ScanFinding, request: ScanRequest, scanID: String,
        config: ScanConfig, now: Date
    ) throws -> FindingAction {
        let result: QuarantineResult
        if config.quarantineEnabled {
            let quarantine = Quarantine(directory: config.quarantineDirectory)
            result = try quarantine.contain(
                filePath: finding.filePath, signature: finding.signature,
                deviceID: request.deviceID, scanID: scanID, now: now
            )
        } else {
            result = .reportedOnly(reason: .policyDisabled)
        }

        let action = result.action
        let quarantinePath: String?
        let reason: ContainmentFailure
        switch result {
        case let .quarantined(path):
            quarantinePath = path
            reason = .readOnlyVolume // unused for the quarantined copy branch
        case let .reportedOnly(r):
            quarantinePath = nil
            reason = r
        }

        try store.insertScanFinding(
            scanID: scanID, filePath: finding.filePath,
            signature: finding.signature, action: action.rawValue, quarantinePath: quarantinePath
        )

        let summary = ScanAlertCopy.infected(
            file: finding.filePath, signature: finding.signature, action: action, reason: reason
        )
        _ = try store.raiseScanAlert(
            deviceID: request.deviceID, severity: "critical",
            summary: summary,
            why: "ClamAV signature “\(finding.signature)” matched \(finding.filePath) on a mounted USB volume.",
            at: now
        )
        return action
    }

    // MARK: - Copy

    private func volumeName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func finishedSummary(report: ScanReport, volume: String, defsNotice: String?) -> String {
        let vol = volumeName(volume)
        var base: String
        switch report.state {
        case .clean:
            base = "Scan of “\(vol)” finished: clean (\(report.filesScanned) file(s))."
        case .infected:
            base = "Scan of “\(vol)” finished: \(report.findings.count) infected file(s) found."
        case .failed:
            base = "Scan of “\(vol)” failed (engine error)."
        case .canceled:
            base = "Scan of “\(vol)” was canceled."
        case .running, .skipped:
            base = "Scan of “\(vol)” finished."
        }
        if let defsNotice {
            base += " Note: \(defsNotice)."
        }
        return base
    }
}
