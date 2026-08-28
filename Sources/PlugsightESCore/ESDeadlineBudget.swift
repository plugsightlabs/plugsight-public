// ESDeadlineBudget.swift
//
// The ES deadline, modeled pure (02: every AUTH handler must respond within
// the ES deadline; respond fast, never block). The plumbing converts the
// message's mach-time deadline to a Date once, then all reasoning is here.
// The budget is exhausted `safetyMargin` seconds BEFORE the kernel deadline,
// because the response must land before it, not at it.

import Foundation

public struct ESDeadlineBudget: Equatable, Sendable {
    /// Absolute wall-clock instant the kernel expects a response by.
    public let deadline: Date
    /// Seconds before `deadline` at which we stop deciding and fail open.
    public let safetyMargin: TimeInterval

    public init(
        deadline: Date,
        safetyMargin: TimeInterval = ESDefaults.deadlineSafetyMargin
    ) {
        self.deadline = deadline
        self.safetyMargin = safetyMargin
    }

    /// Seconds left until the kernel deadline, clamped at zero.
    public func remaining(now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    /// True once fewer than `safetyMargin` seconds remain.
    public func isExhausted(now: Date) -> Bool {
        remaining(now: now) <= safetyMargin
    }
}

extension MountHoldDecider {
    /// Deadline-aware decision: an exhausted budget preempts everything and
    /// ALLOWs — a late DENY would let the kernel kill the client (and is a
    /// worse outcome than an unheld mount, 02).
    public static func decide(
        cache: ESPolicySnapshot?,
        volumeDeviceKey: String?,
        now: Date,
        budget: ESDeadlineBudget,
        ttl: TimeInterval = ESDefaults.policyTTL
    ) -> ESAuthDecision {
        guard !budget.isExhausted(now: now) else {
            return .allow(.deadlineExhausted)
        }
        return decide(cache: cache, volumeDeviceKey: volumeDeviceKey, now: now, ttl: ttl)
    }
}
