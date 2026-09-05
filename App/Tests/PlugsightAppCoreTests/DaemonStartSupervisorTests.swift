// DaemonStartSupervisorTests.swift
//
// The upgrade-hazard state logic (live-walk defect 8): a registered service
// whose daemon never comes up after a start attempt gets ONE automatic
// registration recycle, then the honest advisory. OS calls are the shell's
// job; this is the pure decision table.

import XCTest
@testable import PlugsightAppCore

final class DaemonStartSupervisorTests: XCTestCase {

    func testNoActionWithoutAStartAttempt() {
        var s = DaemonStartSupervisor()
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true), .none)
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true), .none)
    }

    func testReachableDaemonResetsEverything() {
        var s = DaemonStartSupervisor()
        s.noteStartAttempt()
        XCTAssertEqual(s.notePoll(daemonReachable: true, serviceRegistered: true), .none)
        // Fully reset: later unreachable polls (no new attempt) stay silent.
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true), .none)
    }

    func testUnregisteredServiceIsNotThisHazard() {
        var s = DaemonStartSupervisor()
        s.noteStartAttempt()
        for _ in 0..<5 {
            XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: false), .none)
        }
    }

    func testRecycleOnceThenAdvise() {
        var s = DaemonStartSupervisor()
        s.noteStartAttempt()
        // Patience: the first poll after the attempt is not yet a failure.
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true), .none)
        // Registered + still unreachable: recycle the registration once.
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true),
                       .recycleRegistration)
        // Patience again after the recycle.
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true), .none)
        // Still dead: advise, and keep advising (idempotent for the shell).
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true),
                       .advise(DaemonStartSupervisor.updateAdvisory))
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true),
                       .advise(DaemonStartSupervisor.updateAdvisory))
    }

    func testSuccessAfterRecycleResets() {
        var s = DaemonStartSupervisor()
        s.noteStartAttempt()
        _ = s.notePoll(daemonReachable: false, serviceRegistered: true)
        XCTAssertEqual(s.notePoll(daemonReachable: false, serviceRegistered: true),
                       .recycleRegistration)
        XCTAssertEqual(s.notePoll(daemonReachable: true, serviceRegistered: true), .none)
        XCTAssertEqual(s, DaemonStartSupervisor())
    }

    // House rules: shipped prose carries no em dashes and reads sentence case.
    func testAdvisoryCopyFollowsHouseRules() {
        XCTAssertFalse(DaemonStartSupervisor.updateAdvisory.contains("\u{2014}"))
        XCTAssertTrue(DaemonStartSupervisor.updateAdvisory.hasPrefix("Monitoring could not restart"))
    }
}
