// MountHoldFlow.swift
//
// The PURE sequencing of one held volume (05): AUTH_MOUNT deny observed ->
// record + private nobrowse mount -> scan -> on clean, clear the device and
// remount user-visible -> release when the browseable mount is OBSERVED (the
// ground truth, not our own remount call succeeding). Infected keeps the
// volume held; every failure along the way FAILS OPEN into a user-visible
// remount, because a security monitor that strands a drive loses the user
// (02). All decisions live here as a reducer over (phase, input) -> (phase,
// actions); the coordinator executes actions and feeds results back in.

import Foundation

public enum MountHoldFlow {

    /// Why a release happened; drives the honest event summary.
    public enum ReleaseKind: String, Equatable, Sendable {
        /// "Drive released after a clean scan."
        case cleanScan
        /// "Drive released without a completed scan." (fail-open)
        case failOpen
    }

    /// Where one held bsdName stands. nil phase = not tracked.
    public enum Phase: Equatable, Sendable {
        /// Deny observed; waiting for the private mount.
        case held
        /// Private mount up; scan running against it.
        case scanning(privatePath: String)
        /// Remount requested (clean or fail-open); waiting to OBSERVE the
        /// browseable mount before emitting the release.
        case awaitingRemount(ReleaseKind)
        /// Infected: stays held. Cleared only by disk removal.
        case heldInfected
    }

    public enum Input: Equatable, Sendable {
        /// The extension denied this volume's AUTH_MOUNT (untrustedHold).
        case holdObserved
        /// The private nobrowse mount finished: path on success, nil on failure.
        case privateMountResult(path: String?)
        /// The scan reached a terminal state; nil = it could not run at all.
        case scanOutcome(ScanState?)
        /// A BROWSEABLE mount of this volume was observed (ES NOTIFY_MOUNT
        /// without MNT_DONTBROWSE).
        case userVisibleMountObserved
        /// The disk went away (unplugged). Forget everything.
        case diskGone
    }

    public enum Action: Equatable, Sendable {
        /// Append the volume.held event ("Drive held until scanned.").
        case emitHeld
        /// Mount the volume nobrowse at a private path (async; feed
        /// privateMountResult back in).
        case mountPrivate
        /// Run the scan pipeline against the private mount (async; feed
        /// scanOutcome back in).
        case startScan(privatePath: String)
        /// Unmount the private mount (best effort).
        case unmountPrivate(privatePath: String)
        /// Mark the device cleared in the pushed policy (MUST precede the
        /// user-visible remount or the extension re-denies it).
        case clearDevice
        /// Request the user-visible remount (best effort: if it fails, the
        /// clearance still lets the user mount manually, and the release
        /// emits when the mount is actually observed).
        case remountUserVisible
        /// Append the volume.released event with the honest reason.
        case emitReleased(ReleaseKind)
    }

    /// The one transition function. Unknown (phase, input) pairs do nothing:
    /// duplicate denies, late scan results after unplug, and stray mounts are
    /// all absorbed without action.
    public static func reduce(phase: Phase?, input: Input) -> (phase: Phase?, actions: [Action]) {
        switch (phase, input) {

        case (nil, .holdObserved):
            return (.held, [.emitHeld, .mountPrivate])

        case (.held, .privateMountResult(let path?)):
            return (.scanning(privatePath: path), [.startScan(privatePath: path)])

        case (.held, .privateMountResult(nil)):
            // Cannot even mount privately: fail open. Clear first so the
            // remount's AUTH_MOUNT is allowed.
            return (.awaitingRemount(.failOpen), [.clearDevice, .remountUserVisible])

        case (.scanning(let path), .scanOutcome(.clean)):
            return (.awaitingRemount(.cleanScan),
                    [.unmountPrivate(privatePath: path), .clearDevice, .remountUserVisible])

        case (.scanning(let path), .scanOutcome(.infected)):
            // Findings: the scan pipeline already quarantined/alerted. The
            // volume STAYS held; only unplugging forgets it.
            return (.heldInfected, [.unmountPrivate(privatePath: path)])

        case (.scanning(let path), .scanOutcome):
            // failed / canceled / skipped / could-not-run: FAIL OPEN. A drive
            // must never stay stranded because our scanner did.
            return (.awaitingRemount(.failOpen),
                    [.unmountPrivate(privatePath: path), .clearDevice, .remountUserVisible])

        case (.awaitingRemount(let kind), .userVisibleMountObserved):
            // The observed browseable mount is the release's ground truth.
            return (nil, [.emitReleased(kind)])

        case (_, .diskGone):
            // Unplugged at any point: forget. (The pusher separately
            // withdraws the clearance so a re-plug is held again.)
            return (nil, [])

        default:
            return (phase, [])
        }
    }
}
