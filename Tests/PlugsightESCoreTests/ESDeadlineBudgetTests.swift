// ESDeadlineBudgetTests.swift
//
// N12 (02): every AUTH handler must respond within the ES deadline. The
// budget is modeled pure: (deadline, safetyMargin, now) -> exhausted?, and
// the deadline-aware decide() answers ALLOW the moment the budget is gone —
// a late DENY is worse than a fast ALLOW (fail-open).

import XCTest
import PlugsightCore
@testable import PlugsightESCore

final class ESDeadlineBudgetTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_756_000_000)

    func testBudgetWithRoomIsNotExhausted() {
        let budget = ESDeadlineBudget(deadline: now.addingTimeInterval(10))
        XCTAssertFalse(budget.isExhausted(now: now))
        XCTAssertEqual(budget.remaining(now: now), 10, accuracy: 0.001)
    }

    func testBudgetInsideSafetyMarginIsExhausted() {
        // 0.5s left with the default 1.0s margin -> exhausted.
        let budget = ESDeadlineBudget(deadline: now.addingTimeInterval(0.5))
        XCTAssertTrue(budget.isExhausted(now: now))
    }

    func testBudgetExactlyAtMarginIsExhausted() {
        let budget = ESDeadlineBudget(
            deadline: now.addingTimeInterval(ESDefaults.deadlineSafetyMargin)
        )
        XCTAssertTrue(budget.isExhausted(now: now))
    }

    func testPastDeadlineIsExhaustedAndRemainingClampsAtZero() {
        let budget = ESDeadlineBudget(deadline: now.addingTimeInterval(-2))
        XCTAssertTrue(budget.isExhausted(now: now))
        XCTAssertEqual(budget.remaining(now: now), 0)
    }

    func testCustomMarginIsHonored() {
        let budget = ESDeadlineBudget(
            deadline: now.addingTimeInterval(3), safetyMargin: 5
        )
        XCTAssertTrue(budget.isExhausted(now: now))
    }

    // MARK: - Deadline-aware decision: exhausted budget preempts EVERYTHING

    func testExhaustedBudgetAllowsEvenWhenDenyWasDue() {
        // Fresh cache, hold ON, untrusted device — the DENY case — but the
        // budget is gone: answer ALLOW(.deadlineExhausted), never a late DENY.
        let cache = ESPolicySnapshot(
            holdUntilScanned: true,
            trustByDeviceKey: ["k": TrustTier.none],
            bsdNameToDeviceKey: [:],
            pushedAt: now
        )
        let decision = MountHoldDecider.decide(
            cache: cache,
            volumeDeviceKey: "k",
            now: now,
            budget: ESDeadlineBudget(deadline: now.addingTimeInterval(0.1))
        )
        XCTAssertEqual(decision, .allow(.deadlineExhausted))
    }

    func testHealthyBudgetLeavesDecisionUnchanged() {
        let cache = ESPolicySnapshot(
            holdUntilScanned: true,
            trustByDeviceKey: ["k": TrustTier.none],
            bsdNameToDeviceKey: [:],
            pushedAt: now
        )
        let decision = MountHoldDecider.decide(
            cache: cache,
            volumeDeviceKey: "k",
            now: now,
            budget: ESDeadlineBudget(deadline: now.addingTimeInterval(10))
        )
        XCTAssertEqual(decision, .deny(.untrustedHold))
    }
}
