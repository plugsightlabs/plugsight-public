// ScanTypes.swift
//
// Platform-neutral value types shared across the ClamAV orchestration
// (docs/spec/05, 06). These mirror 06's `scans.state` and
// `scan_findings.action` vocabularies exactly, so the daemon never invents a
// state the schema cannot store.

import Foundation

/// ISO-8601 UTC timestamps with millisecond precision, matching the store's own
/// time format (06). Kept here because PlugsightCore's equivalent is internal.
enum ScanTime {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
}

/// Lifecycle state of a scan (06 `scans.state`).
public enum ScanState: String, Equatable, Sendable {
    case running
    case clean
    case infected
    case failed
    case canceled
    case skipped
}

/// What was done with an infected file (06 `scan_findings.action`).
public enum FindingAction: String, Equatable, Sendable {
    /// The file was moved into the quarantine directory with a sidecar.
    case quarantined
    /// Containment failed (e.g. read-only volume); the file was left in place
    /// and only recorded. The alert copy must say so honestly.
    case reportedOnly = "reported_only"
}

/// How a child scan process ended. Produced by `ScanProcessRunner`, consumed by
/// `ScanOutputParser` to derive the terminal `ScanState`.
public enum RunOutcome: Equatable, Sendable {
    /// The process exited on its own with this status code (0 clean, 1 findings,
    /// 2 engine error per the clamscan contract).
    case exited(code: Int32)
    /// The hard timeout elapsed and the runner killed the process group.
    case timedOut
    /// The caller canceled and the runner killed the process group.
    case canceled
}

/// Why containment fell back to report-only. Kept honest so the alert copy can
/// state the real reason rather than a generic one.
public enum ContainmentFailure: Equatable, Sendable {
    /// The volume could not be written (e.g. read-only USB media).
    case readOnlyVolume
    /// The reported path was (or traversed) a symlink; following it to move the
    /// target would be unsafe, so the target was left untouched.
    case unsafeSymlink
    /// Quarantine is turned off in policy; the finding is recorded but the file
    /// is deliberately left in place.
    case policyDisabled
}

/// Outcome of a quarantine attempt for one infected file.
public enum QuarantineResult: Equatable, Sendable {
    /// The file was moved into the quarantine dir at `path` (named by its sha-256).
    case quarantined(path: String)
    /// Containment was not performed; the file was left in place for `reason`.
    case reportedOnly(reason: ContainmentFailure)

    /// The 06 `scan_findings.action` word for this outcome.
    public var action: FindingAction {
        switch self {
        case .quarantined: return .quarantined
        case .reportedOnly: return .reportedOnly
        }
    }
}

/// One per-file verdict parsed from clamscan output.
public struct ScanFinding: Equatable, Sendable {
    /// The path clamscan reported the finding for.
    public let filePath: String
    /// The signature name (e.g. "Eicar-Test-Signature").
    public let signature: String

    public init(filePath: String, signature: String) {
        self.filePath = filePath
        self.signature = signature
    }
}

/// The parsed outcome of a single scan run: a terminal state, the findings, and
/// how many files were scanned. Cancellation and timeout are represented here
/// too (mapped from the process outcome), so callers never re-derive state.
public struct ScanReport: Equatable, Sendable {
    public let state: ScanState
    public let findings: [ScanFinding]
    public let filesScanned: Int

    public init(state: ScanState, findings: [ScanFinding], filesScanned: Int) {
        self.state = state
        self.findings = findings
        self.filesScanned = filesScanned
    }
}
