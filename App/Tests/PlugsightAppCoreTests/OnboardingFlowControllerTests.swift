// OnboardingFlowControllerTests.swift
//
// The runtime wiring between N11's machine and N10's render surface: every
// gesture must re-project the machine state, the welcome step must actually
// register the login item (the whole point of the shipped flow), and the
// completion callback must fire exactly once.

import XCTest
@testable import PlugsightAppCore

@MainActor
final class OnboardingFlowControllerTests: XCTestCase {

    private func makeController(
        probe: FakePermissionProbing = FakePermissionProbing(),
        activator: FakeExtensionActivating = FakeExtensionActivating(),
        loginItem: FakeLoginItemRegistering = FakeLoginItemRegistering(),
        location: FakeAppLocationChecking = FakeAppLocationChecking(),
        onCompleted: @escaping () -> Void = {}
    ) -> OnboardingFlowController {
        let machine = OnboardingStateMachine(
            probe: probe, activator: activator, loginItem: loginItem, location: location)
        return OnboardingFlowController(machine: machine, onCompleted: onCompleted)
    }

    func testInitialRenderStateStartsAtWelcome() {
        let controller = makeController()
        XCTAssertEqual(controller.renderState.currentIndex, 0)
        XCTAssertEqual(controller.renderState.steps.count, 4)
        XCTAssertNil(controller.renderState.completionCopy)
    }

    func testGetStartedRegistersLoginItemAndAdvances() {
        let loginItem = FakeLoginItemRegistering()
        let controller = makeController(loginItem: loginItem)

        controller.primaryAction()

        XCTAssertEqual(loginItem.registrations, 1)
        XCTAssertEqual(controller.renderState.currentIndex, 1)
    }

    func testPollLandsAWaitingGrantAndAdvances() {
        let probe = FakePermissionProbing(inputMonitoring: false)
        let controller = makeController(probe: probe)
        controller.primaryAction()  // welcome -> input monitoring
        controller.primaryAction()  // not granted -> waiting
        XCTAssertEqual(controller.renderState.steps[1].grant, .waiting)

        probe.inputMonitoring = true  // the grant lands in System Settings
        controller.poll()

        XCTAssertEqual(controller.renderState.steps[1].grant, .granted)
        XCTAssertEqual(controller.renderState.currentIndex, 2)
    }

    func testSkipAdvancesWithoutPunishment() {
        let controller = makeController()
        controller.primaryAction()  // welcome
        controller.skip()           // skip input monitoring
        XCTAssertEqual(controller.renderState.currentIndex, 2)
    }

    func testCompletionFiresOnceWithHonestCopy() {
        var completions = 0
        let controller = makeController(onCompleted: { completions += 1 })

        controller.primaryAction()  // welcome
        controller.skip()           // input monitoring
        controller.skip()           // system extension
        controller.skip()           // scanner

        XCTAssertTrue(controller.isComplete)
        XCTAssertNotNil(controller.renderState.completionCopy)
        XCTAssertEqual(completions, 1)

        controller.poll()           // further ticks never re-fire completion
        XCTAssertEqual(completions, 1)
    }
}
