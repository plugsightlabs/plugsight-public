// MountHoldCoordinator.swift
//
// Executes the mount-hold sequence (05) around the PURE MountHoldFlow: maps
// extension events to flow inputs, runs the resulting actions (events into
// the store, private mount, the existing scan pipeline, clearance push,
// user-visible remount), and feeds each async result back in as the next
// input. All state transitions happen serially on one queue; blocking work
// (mounts, the scan child process) runs on background threads.
//
// Event summaries are the record's plain language:
//   volume.held      "Drive held until scanned."
//   volume.released  "Drive released after a clean scan."
//                    "Drive released without a completed scan." (fail-open)

import Foundation
import PlugsightCore
import PlugsightESCore

public final class MountHoldCoordinator: @unchecked Sendable {

    /// What the coordinator needs to know about the device behind a BSD name.
    public struct DeviceRef: Equatable, Sendable {
        public let identityKey: String
        public let deviceID: String?
        public init(identityKey: String, deviceID: String?) {
            self.identityKey = identityKey
            self.deviceID = deviceID
        }
    }

    private let store: EventStore
    private let remounter: VolumeRemounting
    /// The existing scan pipeline (production: ScanOrchestrator.scan with the
    /// live-policy config). Returns the terminal state; throws when the scan
    /// could not run (both fail open).
    private let runScan: @Sendable (ScanRequest) throws -> ScanState
    /// Resolve a BSD name (slice or whole disk) to its device; nil is
    /// tolerated (events then carry no deviceID and no clearance can be
    /// pushed, so the release relies on the extension's own fail-open).
    private let deviceForBSD: @Sendable (String) -> DeviceRef?
    /// Push a post-scan clearance (production: ESPolicyPusher.markCleared).
    private let markCleared: @Sendable (String) -> Void
    private let clock: @Sendable () -> Date

    private let queue = DispatchQueue(label: "plugsight.mount-hold-coordinator")
    private var phases: [String: MountHoldFlow.Phase] = [:]

    public init(
        store: EventStore,
        remounter: VolumeRemounting,
        runScan: @escaping @Sendable (ScanRequest) throws -> ScanState,
        deviceForBSD: @escaping @Sendable (String) -> DeviceRef?,
        markCleared: @escaping @Sendable (String) -> Void,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.remounter = remounter
        self.runScan = runScan
        self.deviceForBSD = deviceForBSD
        self.markCleared = markCleared
        self.clock = clock
    }

    // MARK: - Inputs

    /// Feed one extension event (wired to ESExtensionXPCClient.onEvent).
    public func handle(_ event: ESObservedEvent) {
        guard let bsdName = event.bsdName else { return }
        switch event.kind {
        case .authMountDecision:
            guard case .deny(.untrustedHold) = event.decision else { return }
            apply(input: .holdObserved, bsdName: bsdName)
        case .mount:
            // The private nobrowse mount is our own scan mount, never the
            // release. Only a browseable mount releases the hold.
            guard event.nobrowse != true else { return }
            apply(input: .userVisibleMountObserved, bsdName: bsdName)
        case .unmount, .iokitOpen:
            break
        }
    }

    /// The disk was physically removed (wired to DiskAppearanceWatcher).
    public func diskGone(bsdName: String) {
        apply(input: .diskGone, bsdName: bsdName)
    }

    /// Test/observability hook: the current phase for a BSD name.
    public func phase(forBSDName bsdName: String) -> MountHoldFlow.Phase? {
        queue.sync { phases[bsdName] }
    }

    /// Wait until all queued transitions are applied (tests).
    public func drain() {
        queue.sync {}
    }

    // MARK: - The loop

    private func apply(input: MountHoldFlow.Input, bsdName: String) {
        queue.async { [self] in
            let (phase, actions) = MountHoldFlow.reduce(phase: phases[bsdName], input: input)
            phases[bsdName] = phase
            for action in actions {
                perform(action, bsdName: bsdName)
            }
        }
    }

    private func perform(_ action: MountHoldFlow.Action, bsdName: String) {
        let device = deviceForBSD(bsdName)
        switch action {

        case .emitHeld:
            appendEvent(
                kind: "volume.held", severity: "notice", deviceID: device?.deviceID,
                summary: "Drive held until scanned.",
                detail: ["v": 1, "bsdName": bsdName]
            )

        case .mountPrivate:
            Thread.detachNewThread { [self] in
                let path = try? remounter.mountPrivate(bsdName: bsdName)
                if path == nil {
                    logLine("hold: private mount of \(bsdName) failed; releasing (fail-open)")
                }
                apply(input: .privateMountResult(path: path), bsdName: bsdName)
            }

        case .startScan(let privatePath):
            Thread.detachNewThread { [self] in
                let request = ScanRequest(
                    deviceID: device?.deviceID, volumePath: privatePath, startedBy: "system"
                )
                let outcome = try? runScan(request)
                if outcome == nil {
                    logLine("hold: scan of \(bsdName) could not run; releasing (fail-open)")
                }
                apply(input: .scanOutcome(outcome), bsdName: bsdName)
            }

        case .unmountPrivate:
            Thread.detachNewThread { [self] in
                remounter.unmountPrivate(bsdName: bsdName)
            }

        case .clearDevice:
            if let identityKey = device?.identityKey {
                // Synchronous ON PURPOSE: the clearance must be pushed before
                // the remount below triggers its AUTH_MOUNT.
                markCleared(identityKey)
            } else {
                logLine("hold: no identity for \(bsdName); remount relies on extension fail-open")
            }

        case .remountUserVisible:
            Thread.detachNewThread { [self] in
                do {
                    try remounter.remountUserVisible(bsdName: bsdName)
                } catch {
                    // Best effort: the clearance stands, so a manual mount
                    // works; the release event waits for the observed mount.
                    logLine("hold: user-visible remount of \(bsdName) failed: \(error)")
                }
            }

        case .emitReleased(let kind):
            switch kind {
            case .cleanScan:
                appendEvent(
                    kind: "volume.released", severity: "info", deviceID: device?.deviceID,
                    summary: "Drive released after a clean scan.",
                    detail: ["v": 1, "bsdName": bsdName, "reason": "cleanScan"]
                )
            case .failOpen:
                appendEvent(
                    kind: "volume.released", severity: "notice", deviceID: device?.deviceID,
                    summary: "Drive released without a completed scan.",
                    detail: ["v": 1, "bsdName": bsdName, "reason": "failOpen"]
                )
            }
        }
    }

    // MARK: - Helpers

    private func appendEvent(kind: String, severity: String, deviceID: String?,
                             summary: String, detail: [String: Any]) {
        do {
            let json = String(
                data: try JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]),
                encoding: .utf8
            ) ?? "{\"v\":1}"
            try store.appendEvent(
                kind: kind, severity: severity, deviceID: deviceID,
                summary: summary, detail: json, at: clock()
            )
        } catch {
            logLine("hold: could not append \(kind) event: \(error)")
        }
    }

    private func logLine(_ message: String) {
        FileHandle.standardError.write(Data("plugsightd: \(message)\n".utf8))
    }
}
