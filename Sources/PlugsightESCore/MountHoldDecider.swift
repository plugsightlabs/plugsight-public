// MountHoldDecider.swift
//
// THE enforcement decision (02, 05): should this AUTH_MOUNT be held?
// Pure function over (policyCache, deviceTrust, volumeDeviceKey, freshness).
//
// FAIL-OPEN IS THE LAW (02): a security monitor that can brick mounting on
// its own crash loses the user forever. DENY is returned in exactly one case:
//   holdUntilScanned ON  AND  cache FRESH  AND  the mount is browseable
//   AND device PRESENT in the cache AND its tier is not `.trusted`
//   AND the daemon has not cleared it after a clean hold-scan.
// Every other input — no cache yet, stale cache, unknown device, unresolvable
// volume, a nobrowse (private) mount, a cleared device — ALLOWs, with a
// reason the plumbing logs.

import Foundation
import PlugsightCore

/// Why the decider answered the way it did. Logged by the plumbing on every
/// response so the fail-open paths stay visible in the record.
public enum ESDecisionReason: String, Equatable, Sendable, Codable {
    /// DENY: hold policy on, fresh cache, device known and not trusted.
    case untrustedHold
    /// ALLOW: policy `holdUntilScanned` is off.
    case holdDisabled
    /// ALLOW: device present in the cache with tier `.trusted`.
    case trustedDevice
    /// ALLOW fail-open: no snapshot has ever been pushed.
    case cacheAbsent
    /// ALLOW fail-open: the snapshot is older than the TTL.
    case cacheStale
    /// ALLOW fail-open: volume unresolvable or device not in the table.
    case unknownDevice
    /// ALLOW fail-open: the deadline budget is exhausted (ESDeadline).
    case deadlineExhausted
    /// ALLOW: the daemon cleared this device after a clean hold-scan, so its
    /// user-visible remount (and manual mounts until the clearance is
    /// withdrawn on disk removal) may proceed.
    case scanCleared
    /// ALLOW: the mount is nobrowse (never appears in Finder). The daemon's
    /// PRIVATE scan remount mounts nobrowse; denying it would deadlock the
    /// hold flow, and a nobrowse mount is not the user-facing auto-mount the
    /// hold protects against.
    case nobrowseMount
}

/// The verdict the plumbing maps onto ES_AUTH_RESULT_{ALLOW,DENY}.
public enum ESAuthDecision: Equatable, Sendable {
    case allow(ESDecisionReason)
    case deny(ESDecisionReason)

    /// True only for `.deny`. The plumbing's whole mapping is this bit.
    public var isDeny: Bool {
        if case .deny = self { return true }
        return false
    }

    public var reason: ESDecisionReason {
        switch self {
        case .allow(let r), .deny(let r): return r
        }
    }
}

public enum MountHoldDecider {
    /// Decide one AUTH_MOUNT. Consults ONLY the passed-in cache — by
    /// construction this function cannot block on the daemon (02).
    ///
    /// - Parameters:
    ///   - cache: the latest pushed snapshot, or nil if none ever arrived.
    ///   - volumeDeviceKey: the mounting volume's device identity key, or nil
    ///     when resolution failed (errors fail open).
    ///   - now: the caller's clock (injected for testability).
    ///   - ttl: freshness window, defaulting to ESDefaults.policyTTL.
    ///   - nobrowse: true when the mount carries MNT_DONTBROWSE (it will never
    ///     appear in Finder). The daemon's private scan remount is nobrowse
    ///     and must be allowed or the hold flow deadlocks.
    public static func decide(
        cache: ESPolicySnapshot?,
        volumeDeviceKey: String?,
        now: Date,
        ttl: TimeInterval = ESDefaults.policyTTL,
        nobrowse: Bool = false
    ) -> ESAuthDecision {
        guard let cache else { return .allow(.cacheAbsent) }
        guard cache.holdUntilScanned else { return .allow(.holdDisabled) }
        guard cache.isFresh(now: now, ttl: ttl) else { return .allow(.cacheStale) }
        if nobrowse { return .allow(.nobrowseMount) }
        guard let key = volumeDeviceKey,
              let tier = cache.trustByDeviceKey[key] else {
            return .allow(.unknownDevice)
        }
        // Only `.trusted` exempts. Muted silences notifications (05), it does
        // not confer trust; flagged and none are untrusted by definition.
        if tier == .trusted { return .allow(.trustedDevice) }
        // A clean hold-scan clears the device until it is unplugged (05): the
        // daemon's own user-visible remount comes back through AUTH_MOUNT and
        // must be allowed, or a held drive could never be released.
        if cache.clearedDeviceKeys.contains(key) { return .allow(.scanCleared) }
        return .deny(.untrustedHold)
    }
}
