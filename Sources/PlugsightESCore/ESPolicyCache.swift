// ESPolicyCache.swift
//
// The policy cache the daemon pushes to the ES extension (02): a small table
// device identity -> trust tier, plus the hold-mounts flag, plus the BSD-name
// map that lets the extension resolve a mounting volume to a device identity
// without ever calling back to the daemon. Freshness is a timestamp + TTL so
// that a dead or wedged daemon degrades to fail-open (stale -> ALLOW), never
// to a mount-bricking DENY.

import Foundation
import PlugsightCore

/// Constants for the ES decision layer. Every number is named here so the
/// checker reads one place.
public enum ESDefaults {
    /// How long a pushed policy snapshot stays decision-grade. The daemon
    /// re-pushes on every policy/trust change AND on a heartbeat well inside
    /// this window; a snapshot older than this fails open.
    public static let policyTTL: TimeInterval = 60

    /// Safety margin subtracted from the ES message deadline: we must have
    /// responded BEFORE the kernel deadline, so the budget is treated as
    /// exhausted this many seconds early (02: respond fast, never block).
    public static let deadlineSafetyMargin: TimeInterval = 1.0

    /// The XPC Mach service the extension publishes (name fixed in its
    /// Info.plist, 02). Bundle id of the extension is com.plugsight.esext.
    public static let machServiceName = "com.plugsight.esext.xpc"
}

// TrustTier is declared in PlugsightCore without Codable; the snapshot must
// cross XPC as data, so the conformance is added here (raw-value backed).
extension TrustTier: Codable {}

/// One pushed policy snapshot. Value type, Codable (JSON over XPC), Equatable
/// for tests.
public struct ESPolicySnapshot: Equatable, Sendable, Codable {
    /// Policy `holdUntilScanned` (05). Default off product-wide; the snapshot
    /// carries whatever the daemon's policy store says right now.
    public var holdUntilScanned: Bool

    /// devices.identity_key (06) -> trust tier (05). Devices absent from the
    /// table are CACHE MISSES and fail open.
    public var trustByDeviceKey: [String: TrustTier]

    /// Whole-disk BSD name ("disk4") -> device identity key. Pushed by the
    /// daemon, which owns DiskArbitration; the extension only does the pure
    /// string lookup below.
    public var bsdNameToDeviceKey: [String: String]

    /// When the daemon pushed this snapshot (daemon clock).
    public var pushedAt: Date

    public init(
        holdUntilScanned: Bool,
        trustByDeviceKey: [String: TrustTier],
        bsdNameToDeviceKey: [String: String],
        pushedAt: Date
    ) {
        self.holdUntilScanned = holdUntilScanned
        self.trustByDeviceKey = trustByDeviceKey
        self.bsdNameToDeviceKey = bsdNameToDeviceKey
        self.pushedAt = pushedAt
    }

    /// Fresh iff the snapshot is at most `ttl` old. A pushedAt in the future
    /// (clock skew) counts as fresh: skew must not brick mounting.
    public func isFresh(now: Date, ttl: TimeInterval = ESDefaults.policyTTL) -> Bool {
        now.timeIntervalSince(pushedAt) <= ttl
    }

    /// Resolve a mount's BSD name to a device identity key. Accepts
    /// "/dev/disk4s1", "disk4s1", or "disk4"; slices fall back to their whole
    /// disk. Returns nil on any miss (the decider fails open on nil).
    public func deviceKey(forBSDName raw: String) -> String? {
        var name = raw
        if name.hasPrefix("/dev/") { name.removeFirst("/dev/".count) }
        guard !name.isEmpty else { return nil }
        if let exact = bsdNameToDeviceKey[name] { return exact }
        // diskNsM -> diskN: strip one trailing "s<digits>" if present.
        if let sliceRange = name.range(of: #"s\d+$"#, options: .regularExpression),
           name[name.startIndex..<sliceRange.lowerBound].hasPrefix("disk") {
            return bsdNameToDeviceKey[String(name[name.startIndex..<sliceRange.lowerBound])]
        }
        return nil
    }
}

/// Thread-safe holder for the latest snapshot. The XPC listener writes it;
/// the ES handler thread reads it. A plain lock: the critical section is a
/// pointer swap, well inside any deadline budget.
public final class ESPolicyCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ESPolicySnapshot?

    public init() {}

    public var snapshot: ESPolicySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func update(_ snapshot: ESPolicySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        stored = snapshot
    }
}
