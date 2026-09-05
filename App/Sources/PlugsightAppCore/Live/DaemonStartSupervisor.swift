// DaemonStartSupervisor.swift
//
// Pure state logic for the upgrade hazard the live walk hit: after the app
// bundle is replaced, the registered SMAppService agent dies on launch with a
// Launch Constraint Violation, so "Start monitoring" registers successfully
// and yet the daemon never comes up. The old UI just showed stopped with the
// wrong advice forever.
//
// The supervisor watches the polls that follow a start attempt. When the
// service claims to be registered but the daemon stays unreachable, it first
// asks the shell to recycle the registration ONCE (unregister + register, the
// safe SMAppService cycle that re-points launchd at the new bundle), and only
// if that also fails does it tell the shell to surface the honest advisory.
// Pure by design: the OS calls live in the shell, this type is unit-tested.

import Foundation

public struct DaemonStartSupervisor: Equatable, Sendable {
    /// What the shell should do after feeding a poll result in.
    public enum Action: Equatable, Sendable {
        case none
        /// Unregister + re-register the login item once, then keep polling.
        case recycleRegistration
        /// Surface `updateAdvisory` in the stopped state.
        case advise(String)
    }

    /// The honest post-update copy (no em dashes, sentence case).
    public static let updateAdvisory =
        "Monitoring could not restart after an update. Log out and back in, "
        + "or re-enable Plugsight under Login Items and Extensions."

    /// Polls to wait after an attempt (and after a recycle) before concluding
    /// the daemon is not coming up; at the shell's 5 s heartbeat this gives the
    /// daemon about 10 s to open its socket.
    public static let patiencePolls = 2

    private var startAttempted = false
    private var recycled = false
    private var pollsWaited = 0

    public init() {}

    /// The user pressed Start monitoring (or the shell re-registered).
    public mutating func noteStartAttempt() {
        startAttempted = true
        pollsWaited = 0
    }

    /// Feed one heartbeat poll. `daemonReachable` is whether status.get
    /// answered; `serviceRegistered` is the SMAppService status.
    public mutating func notePoll(daemonReachable: Bool, serviceRegistered: Bool) -> Action {
        guard startAttempted else { return .none }
        if daemonReachable {
            // The daemon came up: the attempt succeeded, forget everything.
            self = DaemonStartSupervisor()
            return .none
        }
        // An unregistered service is not this hazard (the register itself
        // failed; the ordinary stopped state already covers it).
        guard serviceRegistered else { return .none }
        pollsWaited += 1
        guard pollsWaited >= Self.patiencePolls else { return .none }
        if !recycled {
            recycled = true
            pollsWaited = 0
            return .recycleRegistration
        }
        return .advise(Self.updateAdvisory)
    }
}
