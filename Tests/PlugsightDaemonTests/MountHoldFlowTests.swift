// MountHoldFlowTests.swift
//
// The pure hold sequencing (05): every deny leads either to a clean release,
// an infected keep-hold, or a FAIL-OPEN release. The reducer is the whole
// decision surface — the coordinator only executes actions — so these tests
// are the flow's contract. Every deny path has its allow-on-failure twin
// asserted here (fail-open law, 02).

import XCTest
@testable import PlugsightDaemon

final class MountHoldFlowTests: XCTestCase {

    typealias Flow = MountHoldFlow

    // MARK: - The happy path: deny -> scan clean -> release

    func testDenyStartsHoldWithRecordAndPrivateMount() {
        let (phase, actions) = Flow.reduce(phase: nil, input: .holdObserved)
        XCTAssertEqual(phase, .held)
        XCTAssertEqual(actions, [.emitHeld, .mountPrivate])
    }

    func testPrivateMountSuccessStartsTheScan() {
        let (phase, actions) = Flow.reduce(phase: .held, input: .privateMountResult(path: "/priv/disk4s1"))
        XCTAssertEqual(phase, .scanning(privatePath: "/priv/disk4s1"))
        XCTAssertEqual(actions, [.startScan(privatePath: "/priv/disk4s1")])
    }

    func testCleanScanClearsThenRemounts() {
        let (phase, actions) = Flow.reduce(
            phase: .scanning(privatePath: "/priv/disk4s1"), input: .scanOutcome(.clean)
        )
        XCTAssertEqual(phase, .awaitingRemount(.cleanScan))
        XCTAssertEqual(actions, [
            .unmountPrivate(privatePath: "/priv/disk4s1"),
            .clearDevice,               // MUST precede the remount: the remount's
            .remountUserVisible,        // AUTH_MOUNT is only allowed once cleared
        ])
    }

    func testObservedBrowseableMountEmitsTheCleanRelease() {
        let (phase, actions) = Flow.reduce(
            phase: .awaitingRemount(.cleanScan), input: .userVisibleMountObserved
        )
        XCTAssertNil(phase, "released: the volume is no longer tracked")
        XCTAssertEqual(actions, [.emitReleased(.cleanScan)])
    }

    // MARK: - Infected: stays held

    func testInfectedScanKeepsTheVolumeHeld() {
        let (phase, actions) = Flow.reduce(
            phase: .scanning(privatePath: "/priv/disk4s1"), input: .scanOutcome(.infected)
        )
        XCTAssertEqual(phase, .heldInfected)
        XCTAssertEqual(actions, [.unmountPrivate(privatePath: "/priv/disk4s1")],
                       "no clearance, no remount, no release: infected stays held")
    }

    func testInfectedHoldForgetsOnUnplug() {
        let (phase, actions) = Flow.reduce(phase: .heldInfected, input: .diskGone)
        XCTAssertNil(phase)
        XCTAssertEqual(actions, [])
    }

    // MARK: - Fail-open twins (every failure releases)

    func testPrivateMountFailureFailsOpen() {
        let (phase, actions) = Flow.reduce(phase: .held, input: .privateMountResult(path: nil))
        XCTAssertEqual(phase, .awaitingRemount(.failOpen))
        XCTAssertEqual(actions, [.clearDevice, .remountUserVisible])
    }

    func testFailedScanFailsOpen() {
        let (phase, actions) = Flow.reduce(
            phase: .scanning(privatePath: "/p"), input: .scanOutcome(.failed)
        )
        XCTAssertEqual(phase, .awaitingRemount(.failOpen))
        XCTAssertEqual(actions, [.unmountPrivate(privatePath: "/p"), .clearDevice, .remountUserVisible])
    }

    func testCanceledAndSkippedAndUnrunnableScansFailOpen() {
        for outcome in [ScanState.canceled, .skipped, nil] {
            let (phase, actions) = Flow.reduce(
                phase: .scanning(privatePath: "/p"), input: .scanOutcome(outcome)
            )
            XCTAssertEqual(phase, .awaitingRemount(.failOpen), "outcome \(String(describing: outcome))")
            XCTAssertTrue(actions.contains(.remountUserVisible),
                          "a scan that did not finish clean must still release (fail-open)")
        }
    }

    func testFailOpenReleaseCarriesItsHonestReason() {
        let (phase, actions) = Flow.reduce(
            phase: .awaitingRemount(.failOpen), input: .userVisibleMountObserved
        )
        XCTAssertNil(phase)
        XCTAssertEqual(actions, [.emitReleased(.failOpen)])
    }

    // MARK: - Absorbed noise

    func testDuplicateDenyWhileTrackedDoesNothing() {
        for phase in [Flow.Phase.held, .scanning(privatePath: "/p"),
                      .awaitingRemount(.cleanScan), .heldInfected] {
            let (next, actions) = Flow.reduce(phase: phase, input: .holdObserved)
            XCTAssertEqual(next, phase)
            XCTAssertEqual(actions, [], "a repeat deny (mount retry) must not restart the flow")
        }
    }

    func testStrayMountForUntrackedVolumeDoesNothing() {
        let (phase, actions) = Flow.reduce(phase: nil, input: .userVisibleMountObserved)
        XCTAssertNil(phase)
        XCTAssertEqual(actions, [])
    }

    func testLateScanResultAfterUnplugDoesNothing() {
        let (phase, actions) = Flow.reduce(phase: nil, input: .scanOutcome(.clean))
        XCTAssertNil(phase)
        XCTAssertEqual(actions, [])
    }

    func testDiskGoneForgetsAtEveryPhase() {
        for phase in [Flow.Phase.held, .scanning(privatePath: "/p"),
                      .awaitingRemount(.failOpen), .heldInfected] {
            let (next, actions) = Flow.reduce(phase: phase, input: .diskGone)
            XCTAssertNil(next, "from \(phase)")
            XCTAssertEqual(actions, [])
        }
    }
}
