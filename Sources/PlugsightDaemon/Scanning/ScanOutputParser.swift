// ScanOutputParser.swift
//
// Parse clamscan/clamdscan stdout into per-file verdicts, and map the process
// outcome to a terminal `ScanState` (docs/spec/05). The exit-code contract is
// load-bearing: 0 = clean, 1 = findings, 2 = engine error rendered as `failed`
// and NEVER as clean. Timeout maps to `failed`; cancellation to `canceled`.
//
// clamscan prints one line per file:
//   /path/to/file: OK
//   /path/to/file: Some-Signature-Name FOUND
// followed by a "SCAN SUMMARY" block we do not rely on for verdicts.

import Foundation

public enum ScanOutputParser {

    /// Extract the infected findings from clamscan stdout, in the order printed.
    public static func findings(from stdout: String) -> [ScanFinding] {
        var result: [ScanFinding] = []
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.hasSuffix(" FOUND") else { continue }
            // Format: "<path>: <signature> FOUND". Split on the LAST ": " before
            // the signature so paths containing ": " are still handled: clamscan
            // separates path and verdict with the final ": ".
            guard let sep = line.range(of: ": ", options: .backwards) else { continue }
            let path = String(line[line.startIndex..<sep.lowerBound])
            let verdict = String(line[sep.upperBound...])
            guard verdict.hasSuffix(" FOUND") else { continue }
            let signature = String(verdict.dropLast(" FOUND".count))
            guard !signature.isEmpty else { continue }
            result.append(ScanFinding(filePath: path, signature: signature))
        }
        return result
    }

    /// Count the per-file verdict lines (both OK and FOUND) as files scanned.
    public static func filesScanned(from stdout: String) -> Int {
        stdout.split(separator: "\n", omittingEmptySubsequences: true).reduce(into: 0) { acc, rawLine in
            let line = String(rawLine)
            if line.hasSuffix(": OK") || line.hasSuffix(" FOUND") { acc += 1 }
        }
    }

    /// Map a process outcome + stdout to a terminal report. The exit code is the
    /// authority on state; stdout only enumerates findings and files.
    public static func report(outcome: RunOutcome, stdout: String) -> ScanReport {
        let scanned = filesScanned(from: stdout)
        switch outcome {
        case .canceled:
            return ScanReport(state: .canceled, findings: [], filesScanned: scanned)
        case .timedOut:
            return ScanReport(state: .failed, findings: [], filesScanned: scanned)
        case let .exited(code):
            switch code {
            case 0:
                // Clean: trust the exit code, ignore any stray FOUND text.
                return ScanReport(state: .clean, findings: [], filesScanned: scanned)
            case 1:
                let found = findings(from: stdout)
                return ScanReport(state: .infected, findings: found, filesScanned: scanned)
            default:
                // 2 (engine error) or any other non-{0,1} code: failed, never clean.
                return ScanReport(state: .failed, findings: [], filesScanned: scanned)
            }
        }
    }
}
