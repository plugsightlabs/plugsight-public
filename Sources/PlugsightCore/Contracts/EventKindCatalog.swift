// EventKindCatalog.swift
//
// The single canonical definition of the CLOSED SET of event kinds the daemon
// emits in v1 (docs/spec/06, "Event kind catalog"). This list is namespaced,
// closed per release, and is the source of truth for:
//
//   - `plugsightd --print-catalog` (which prints this list verbatim), and
//   - the capability drift gate (`ops/check-drift.mjs`), which cross-checks the
//     README capability table and the docs against exactly this set.
//
// There must be NO OTHER hardcoded list of the full catalog anywhere. Individual
// emit sites use their own string literal for the one kind they write; this file
// is the only place that enumerates the whole closed set. Keep the order stable
// (it matches the 06 catalog table top-to-bottom): the print output and the gate
// treat the order as deterministic.
//
// Consumed by: plugsightd (--print-catalog), and asserted against by the drift gate.

/// The closed set of event kinds the daemon may emit in v1, in the canonical
/// (spec 06) order. Adding or removing a kind here is a deliberate catalog change
/// and will make the drift gate require a matching README / docs update.
public enum EventKindCatalog {
    /// The v1 closed set, in stable spec-06 order. This is THE canonical list.
    public static let all: [String] = [
        "device.attached",
        "device.detached",
        "device.interfaces_changed",
        "mismatch.detected",
        "mismatch.allowlisted",
        "hid.typing_burst",
        "score.changed",
        "alert.raised",
        "alert.acknowledged",
        "alert.resolved",
        "trust.changed",
        "volume.mounted",
        "volume.unmounted",
        "volume.held",
        "volume.released",
        "scan.started",
        "scan.finished",
        "scan.skipped",
        "quarantine.restored",
        "esext.iokit_open",
        "daemon.started",
        "daemon.stopped",
        "monitoring.gap",
    ]

    /// The catalog as a deterministic JSON document, sorted for stability, with a
    /// declared count so consumers can assert they parsed the whole thing. This is
    /// exactly what `plugsightd --print-catalog` writes to stdout.
    public static func printableJSON() -> String {
        let sorted = all.sorted()
        var lines: [String] = []
        lines.append("{")
        lines.append("  \"generator\": \"plugsightd --print-catalog\",")
        lines.append("  \"eventKindCount\": \(sorted.count),")
        lines.append("  \"eventKinds\": [")
        for (index, kind) in sorted.enumerated() {
            let comma = index == sorted.count - 1 ? "" : ","
            lines.append("    \"\(kind)\"\(comma)")
        }
        lines.append("  ]")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}
