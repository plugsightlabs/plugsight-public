// ScanConfigResolver.swift  (N8b — Gap B)
//
// Build the ScanConfig for a scan from the LIVE `policy` rows, rather than from
// hardcoded constants. Both the API `scan.start` path and the mount-triggered
// path call this at scan time, so an operator's `policy.set` (quarantine,
// scanTimeoutMinutes, definitionsWarnDays) takes effect for subsequent scans.
//
// The policy rows arrive as `[key: JSON-value bytes]` (APIStore.policyRaw); each
// value is one JSON scalar exactly as `policy.set` stored it. Unknown/unparsable
// rows are ignored, so the config degrades to the base rather than failing a scan.

import Foundation

enum ScanConfigResolver {

    /// Overlay the scan-relevant policy rows on top of `base` (the v1 defaults +
    /// this daemon's quarantine directory). The quarantine directory is never
    /// policy-driven, so it is always carried through from `base`.
    static func resolve(base: ScanConfig, policyRaw: [String: Data]) -> ScanConfig {
        var timeout = base.timeout
        var quarantine = base.quarantineEnabled
        var defsWarn = base.definitionsWarnDays

        for (key, data) in policyRaw {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            switch key {
            case "scanTimeoutMinutes":
                if let minutes = value.intValue { timeout = TimeInterval(max(1, minutes) * 60) }
            case "quarantine":
                if let on = value.boolValue { quarantine = on }
            case "definitionsWarnDays":
                if let days = value.intValue { defsWarn = days }
            default:
                break   // scanOnMount / clamdSocketPath / holdUntilScanned / retentionDays: not ScanConfig knobs
            }
        }

        return ScanConfig(
            timeout: timeout,
            quarantineEnabled: quarantine,
            definitionsWarnDays: defsWarn,
            quarantineDirectory: base.quarantineDirectory
        )
    }
}
