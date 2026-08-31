// EngineDiscovery.swift
//
// Resolve which ClamAV front-end to use (docs/spec/05). Discovery order, at
// daemon start and on demand:
//   1. A running `clamd` (socket from policy, default the Homebrew path) -> use
//      `clamdscan` against that socket.
//   2. Else `clamscan` on PATH or in the Homebrew locations.
//   3. Else `unavailable`, carrying the install fix surfaced in Settings and in
//      any scan-attempt error.
//
// Every probe (socket liveness, executable lookup, file existence) is INJECTABLE
// so tests point discovery at the fake clamscan fixtures and simulate a live or
// dead daemon without touching the host.

import Foundation

/// The resolved engine, or `unavailable` with the user-facing install fix.
public enum ResolvedEngine: Equatable, Sendable {
    case clamdscan(executable: String, socket: String)
    case clamscan(executable: String)
    case unavailable(installFix: String)
}

public struct EngineDiscovery {

    /// The exact remediation copy shown in Settings and in any scan-attempt error
    /// when no engine is present (05).
    public static let installFix =
        "ClamAV is not installed. Install it with: brew install clamav, then run "
        + "freshclam once to download the signature definitions before scanning."

    /// Default executable search locations (Homebrew on Apple Silicon and Intel,
    /// plus the conventional PATH dirs). Used only for lookups the caller does not
    /// override.
    public static let defaultSearchDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    private let clamdSocketPath: String
    private let clamdSocketLive: (String) -> Bool
    private let candidateExecutables: [String: String]
    private let searchDirs: [String]
    private let fileExists: (String) -> Bool

    /// - Parameters:
    ///   - clamdSocketPath: policy-configured clamd socket (default Homebrew path).
    ///   - clamdSocketLive: probe for a live daemon on that socket.
    ///   - candidateExecutables: pre-resolved absolute paths per tool name; when a
    ///     tool is absent here it is searched for in `searchDirs`.
    ///   - searchDirs: directories to look for the tool binaries in.
    ///   - fileExists: existence probe (injected in tests).
    public init(
        clamdSocketPath: String = "/opt/homebrew/var/run/clamav/clamd.sock",
        clamdSocketLive: @escaping (String) -> Bool,
        candidateExecutables: [String: String] = [:],
        searchDirs: [String] = EngineDiscovery.defaultSearchDirs,
        fileExists: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.clamdSocketPath = clamdSocketPath
        self.clamdSocketLive = clamdSocketLive
        self.candidateExecutables = candidateExecutables
        self.searchDirs = searchDirs
        self.fileExists = fileExists
    }

    /// Resolve the engine in the documented order.
    public func resolve() -> ResolvedEngine {
        if clamdSocketLive(clamdSocketPath), let clamdscan = locate("clamdscan") {
            return .clamdscan(executable: clamdscan, socket: clamdSocketPath)
        }
        if let clamscan = locate("clamscan") {
            return .clamscan(executable: clamscan)
        }
        return .unavailable(installFix: Self.installFix)
    }

    /// Find a tool: prefer a pre-resolved path, else scan `searchDirs`. Only a
    /// path that `fileExists` accepts is returned.
    private func locate(_ tool: String) -> String? {
        if let path = candidateExecutables[tool], fileExists(path) {
            return path
        }
        for dir in searchDirs {
            let path = dir + "/" + tool
            if fileExists(path) { return path }
        }
        return nil
    }
}
