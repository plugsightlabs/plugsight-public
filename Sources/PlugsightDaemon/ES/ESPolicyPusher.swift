// ESPolicyPusher.swift
//
// Builds and pushes ESPolicySnapshot to the ES extension (02): the policy
// `holdUntilScanned` flag, the trust table (device identity key -> tier), the
// BSD-name map that lets the extension resolve a mounting volume to a device
// WITHOUT calling back to the daemon, and the post-scan clearances. Pushes
// happen on connect, on every policy/trust change, on disk topology change,
// and on a heartbeat well inside the snapshot TTL so a live daemon's cache
// never goes stale (a DEAD daemon's cache does, and stale fails open — that
// is the designed failure mode, docs/spec/05).

import Foundation
import PlugsightCore
import PlugsightESCore

/// Policy-row reads the boot wiring needs (JSONValue is internal to this
/// module, so the decode lives here rather than in main.swift).
public enum ESPolicyReads {
    /// The live `holdUntilScanned` flag from raw policy rows, defaulting like
    /// every other policy read (absent/unparsable = the v1 default, false).
    public static func holdUntilScanned(from raw: [String: Data]) -> Bool {
        guard let data = raw["holdUntilScanned"],
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let on = value.boolValue else {
            return PolicyObject.defaults.holdUntilScanned
        }
        return on
    }

    /// The live-policy scan config for the hold scan (the same resolver the
    /// mount and API scan paths use; ScanConfigResolver is module-internal).
    public static func liveScanConfig(base: ScanConfig, from raw: [String: Data]) -> ScanConfig {
        ScanConfigResolver.resolve(base: base, policyRaw: raw)
    }
}

public final class ESPolicyPusher: @unchecked Sendable {

    /// Sends one snapshot to the extension (production: ESExtensionXPCClient
    /// .push; tests: a recorder).
    public typealias Send = @Sendable (ESPolicySnapshot) -> Void

    private let holdPolicyProvider: @Sendable () -> Bool
    private let trustProvider: @Sendable () -> [String: TrustTier]
    /// Resolves a COLLECTOR device key (transient, from the IOKit/DA walk) to
    /// the store's durable identity key; nil when the device has not been
    /// analyzed yet (the entry is retried on the next push).
    private let identityResolver: @Sendable (String) -> String?
    private let send: Send
    private let clock: @Sendable () -> Date
    private let heartbeatInterval: TimeInterval

    private let lock = NSLock()
    /// BSD name -> collector device key, as reported by disk appearance.
    private var disksByBSDName: [String: String] = [:]
    /// Identity keys cleared after a clean hold-scan (withdrawn on disk gone).
    private var clearedIdentityKeys: Set<String> = []
    private var heartbeatTask: Task<Void, Never>?

    public init(
        holdPolicyProvider: @escaping @Sendable () -> Bool,
        trustProvider: @escaping @Sendable () -> [String: TrustTier],
        identityResolver: @escaping @Sendable (String) -> String?,
        send: @escaping Send,
        heartbeatInterval: TimeInterval = ESDefaults.policyTTL / 3,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.holdPolicyProvider = holdPolicyProvider
        self.trustProvider = trustProvider
        self.identityResolver = identityResolver
        self.send = send
        self.heartbeatInterval = heartbeatInterval
        self.clock = clock
    }

    // MARK: - Disk topology (from DiskAppearanceWatcher)

    /// A disk (whole disk or slice) appeared: remember its owning collector
    /// device key and push, so the extension can resolve the imminent
    /// AUTH_MOUNT. Resolution to the identity key happens per push, because
    /// the analyzer may not have upserted the device yet when the disk shows.
    public func diskAppeared(bsdName: String, collectorDeviceKey: String) {
        lock.lock()
        disksByBSDName[bsdName] = collectorDeviceKey
        lock.unlock()
        pushNow()
    }

    /// A disk went away: drop its map entry AND withdraw any clearance for
    /// its device (a re-plug must be held and scanned again, 05).
    public func diskGone(bsdName: String) {
        lock.lock()
        let collectorKey = disksByBSDName.removeValue(forKey: bsdName)
        lock.unlock()
        if let collectorKey, let identity = identityResolver(collectorKey) {
            lock.lock()
            clearedIdentityKeys.remove(identity)
            lock.unlock()
        }
        pushNow()
    }

    // MARK: - Post-scan clearance (from MountHoldCoordinator)

    /// Mark a device cleared after a clean hold-scan and push immediately, so
    /// the user-visible remount that follows is allowed.
    public func markCleared(identityKey: String) {
        lock.lock()
        clearedIdentityKeys.insert(identityKey)
        lock.unlock()
        pushNow()
    }

    // MARK: - Push

    /// Build the current snapshot and send it. Called by every trigger; also
    /// the heartbeat body.
    public func pushNow() {
        send(currentSnapshot())
    }

    /// The snapshot as of now (also used by tests to assert content).
    public func currentSnapshot() -> ESPolicySnapshot {
        lock.lock()
        let disks = disksByBSDName
        let cleared = clearedIdentityKeys
        lock.unlock()

        var bsdMap: [String: String] = [:]
        for (bsd, collectorKey) in disks {
            if let identity = identityResolver(collectorKey) {
                bsdMap[bsd] = identity
            }
            // Unresolved entries are omitted: the decider fails open on a
            // missing mapping, and the next push retries the resolution.
        }
        return ESPolicySnapshot(
            holdUntilScanned: holdPolicyProvider(),
            trustByDeviceKey: trustProvider(),
            bsdNameToDeviceKey: bsdMap,
            pushedAt: clock(),
            clearedDeviceKeys: cleared
        )
    }

    // MARK: - Heartbeat

    /// Re-push on an interval well inside the TTL (default TTL/3), so a live
    /// daemon's snapshot never goes stale between event-driven pushes.
    public func startHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        guard heartbeatTask == nil else { return }
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.pushNow()
            }
        }
    }

    public func stopHeartbeat() {
        lock.lock()
        let task = heartbeatTask
        heartbeatTask = nil
        lock.unlock()
        task?.cancel()
    }
}
