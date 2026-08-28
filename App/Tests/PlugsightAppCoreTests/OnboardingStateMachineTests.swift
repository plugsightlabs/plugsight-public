// OnboardingStateMachineTests.swift
//
// N11: the PURE step state machine (04 "Onboarding window" + stories 1a-1e).
// Driven entirely through FAKE permission drivers, so every transition is
// deterministic and CI-testable without TCC, SMAppService, the system
// extension, or being in /Applications. The REAL macOS drivers are thin and
// unit-untestable by design; this suite proves the LOGIC that drives them.
//
// Covered: grant-lands -> step completes; denial -> degraded consequence copy +
// working deep link; Skip is available at EVERY step and never punished; the
// /Applications location check (1d) gates the extension step and fires its move
// instruction BEFORE activation is attempted; completion copy is honest for
// every combination (all granted / some denied / all skipped).

import XCTest
@testable import PlugsightAppCore

final class OnboardingStateMachineTests: XCTestCase {

    // MARK: - fixtures

    private func machine(
        inputMonitoring: Bool = false,
        fullDiskAccess: Bool = false,
        extensionActive: Bool = false,
        inApplications: Bool = true
    ) -> (OnboardingStateMachine, FakePermissionProbing, FakeExtensionActivating,
          FakeLoginItemRegistering, FakeAppLocationChecking) {
        let probe = FakePermissionProbing()
        probe.inputMonitoring = inputMonitoring
        probe.fullDiskAccess = fullDiskAccess
        let activator = FakeExtensionActivating()
        activator.active = extensionActive
        let login = FakeLoginItemRegistering()
        let location = FakeAppLocationChecking()
        location.inApplications = inApplications
        let sm = OnboardingStateMachine(probe: probe, activator: activator,
                                        loginItem: login, location: location)
        return (sm, probe, activator, login, location)
    }

    /// Advance welcome -> the given permission step by pressing Get started then
    /// skipping the steps in between (skip is always allowed).
    private func advanceToInputMonitoring(_ sm: OnboardingStateMachine) {
        sm.getStarted()
    }

    // MARK: - shape

    func testStartsAtWelcomeWithFourStepsInOrder() {
        let (sm, _, _, _, _) = machine()
        XCTAssertEqual(sm.state.steps.map(\.kind),
                       [.welcome, .inputMonitoring, .systemExtension, .scanner])
        XCTAssertEqual(sm.state.currentIndex, 0)
        XCTAssertEqual(sm.state.currentStep.kind, .welcome)
        XCTAssertNil(sm.state.resultingMode)
    }

    func testGetStartedRegistersLoginItemAndAdvances() {
        let (sm, _, _, login, _) = machine()
        sm.getStarted()
        XCTAssertEqual(login.registrations, 1, "Get started should register the agent login item")
        XCTAssertEqual(sm.state.currentStep.kind, .inputMonitoring)
    }

    // MARK: - grant lands -> step completes

    func testGrantLandsWhenRequestedCompletesStepAndAdvances() {
        let (sm, probe, _, _, _) = machine(inputMonitoring: true)
        sm.getStarted()                       // -> Input Monitoring
        XCTAssertEqual(sm.state.currentStep.kind, .inputMonitoring)
        sm.requestCurrentGrant()              // already granted -> completes
        XCTAssertEqual(sm.state.step(.inputMonitoring).status, .granted)
        XCTAssertEqual(sm.state.currentStep.kind, .systemExtension)
        _ = probe
    }

    func testPendingGrantMovesToWaitingThenGrantLandsOnPoll() {
        let (sm, probe, _, _, _) = machine(inputMonitoring: false)
        sm.getStarted()
        sm.requestCurrentGrant()              // not granted yet
        XCTAssertEqual(sm.state.step(.inputMonitoring).status, .waitingForSystemSettings)
        XCTAssertEqual(sm.state.currentStep.kind, .inputMonitoring, "still on the step while waiting")
        // The user grants it in System Settings; the next poll sees it land.
        probe.inputMonitoring = true
        sm.poll()
        XCTAssertEqual(sm.state.step(.inputMonitoring).status, .granted)
        XCTAssertEqual(sm.state.currentStep.kind, .systemExtension, "landed grant advances")
    }

    // MARK: - denial -> degraded copy + deep link

    func testDenialProducesDegradedConsequenceCopyAndDeepLink() {
        let (sm, _, _, _, _) = machine()
        sm.getStarted()                       // Input Monitoring
        sm.denyCurrent()
        guard case let .denied(consequence, link) = sm.state.step(.inputMonitoring).status else {
            return XCTFail("expected denied")
        }
        XCTAssertFalse(consequence.isEmpty, "degraded consequence copy present")
        XCTAssertTrue(consequence.lowercased().contains("typing"),
                      "IM denial names the honest consequence (1b)")
        XCTAssertTrue(link.url.hasPrefix("x-apple.systempreferences:"),
                      "deep link points at System Settings")
        XCTAssertFalse(link.label.isEmpty)
        XCTAssertEqual(sm.state.currentStep.kind, .systemExtension, "denial is not a wall; it advances")
    }

    func testEveryPermissionStepHasADistinctDegradedConsequenceAndLink() {
        for kind in [OnboardingStepKind.inputMonitoring, .systemExtension, .scanner] {
            let pair = OnboardingStateMachine.degradedConsequence(for: kind)
            XCTAssertNotNil(pair, "\(kind) has a degraded consequence")
            XCTAssertFalse(pair!.copy.isEmpty)
            XCTAssertTrue(pair!.deepLink.url.hasPrefix("x-apple.systempreferences:"))
        }
        // Welcome has no permission and thus no degraded consequence.
        XCTAssertNil(OnboardingStateMachine.degradedConsequence(for: .welcome))
    }

    // MARK: - Skip is always available and never punished

    func testSkipIsAvailableAtEveryStepAndAdvances() {
        let (sm, _, _, _, _) = machine()
        // Skip is offered on the welcome step and every permission step.
        for _ in 0..<4 {
            XCTAssertTrue(sm.skipAvailable, "Skip is available at \(sm.state.currentStep.kind)")
            sm.skipCurrent()
        }
        // After skipping all four, the walk is complete.
        XCTAssertNotNil(sm.state.resultingMode)
    }

    func testSkipMarksTheStepSkippedNotDenied() {
        let (sm, _, _, _, _) = machine()
        sm.getStarted()
        sm.skipCurrent()
        XCTAssertEqual(sm.state.step(.inputMonitoring).status, .skipped)
        // Skipping never writes a denied/degraded status (not punished).
        if case .denied = sm.state.step(.inputMonitoring).status {
            XCTFail("skip must not produce a denied state")
        }
    }

    func testSkipAvailableEvenWhileWaiting() {
        let (sm, _, _, _, _) = machine(inputMonitoring: false)
        sm.getStarted()
        sm.requestCurrentGrant()  // -> waiting
        XCTAssertEqual(sm.state.step(.inputMonitoring).status, .waitingForSystemSettings)
        XCTAssertTrue(sm.skipAvailable, "Skip stays available while waiting for System Settings")
        sm.skipCurrent()
        XCTAssertEqual(sm.state.step(.inputMonitoring).status, .skipped)
    }

    // MARK: - location check (1d) gates the extension step

    func testWrongLocationShowsMoveInstructionBeforeActivationIsAttempted() {
        let (sm, _, activator, _, location) = machine(inApplications: false)
        location.moveInstruction = "Move Plugsight to Applications, then reopen it."
        sm.getStarted()
        sm.skipCurrent()               // skip Input Monitoring -> System Extension
        XCTAssertEqual(sm.state.currentStep.kind, .systemExtension)
        sm.requestCurrentGrant()       // Activate pressed while OUT of /Applications
        XCTAssertEqual(activator.activationRequests, 0,
                       "activation MUST NOT be attempted from the wrong location (1d)")
        XCTAssertEqual(sm.state.step(.systemExtension).locationInstruction,
                       "Move Plugsight to Applications, then reopen it.")
        XCTAssertEqual(sm.state.currentStep.kind, .systemExtension, "stays on the step until moved")
        XCTAssertEqual(sm.state.step(.systemExtension).status, .pending)
    }

    func testCorrectLocationAllowsActivationToBeDriven() {
        let (sm, _, act, _, _) = machine(inApplications: true)
        sm.getStarted(); sm.skipCurrent()  // -> System Extension
        sm.requestCurrentGrant()
        XCTAssertEqual(act.activationRequests, 1, "activation is driven when in /Applications")
        XCTAssertEqual(sm.state.step(.systemExtension).status, .waitingForSystemSettings)
        XCTAssertNil(sm.state.step(.systemExtension).locationInstruction)
    }

    // MARK: - completion copy is honest for every combination

    func testCompletionAllGrantedIsActiveAndHonest() {
        let probe = FakePermissionProbing(); probe.inputMonitoring = true; probe.fullDiskAccess = true
        let act = FakeExtensionActivating(); act.active = true
        let login = FakeLoginItemRegistering()
        let loc = FakeAppLocationChecking()
        let sm = OnboardingStateMachine(probe: probe, activator: act, loginItem: login, location: loc)
        sm.getStarted()
        sm.requestCurrentGrant()  // IM granted
        sm.requestCurrentGrant()  // extension active
        sm.requestCurrentGrant()  // FDA granted -> completes
        let mode = sm.state.resultingMode
        XCTAssertEqual(mode?.outcome, .active)
        XCTAssertTrue(mode!.copy.lowercased().contains("active"))
    }

    func testCompletionSomeDeniedIsDegradedAndNamesTheMissingGrant() {
        let (sm, _, _, _, _) = machine(inputMonitoring: false, fullDiskAccess: true, extensionActive: true)
        sm.getStarted()
        sm.denyCurrent()          // deny Input Monitoring
        sm.requestCurrentGrant()  // extension active -> granted
        sm.requestCurrentGrant()  // FDA -> granted, completes
        let mode = sm.state.resultingMode
        XCTAssertEqual(mode?.outcome, .degraded)
        XCTAssertTrue(mode!.copy.contains("Input Monitoring"),
                      "degraded copy names the recognizable missing grant (04)")
    }

    func testCompletionAllSkippedIsConnectionsOnly() {
        let (sm, _, _, _, _) = machine()
        sm.skipCurrent()  // welcome
        sm.skipCurrent()  // input monitoring
        sm.skipCurrent()  // system extension
        sm.skipCurrent()  // scanner -> completes
        let mode = sm.state.resultingMode
        XCTAssertEqual(mode?.outcome, .connectionsOnly)
        XCTAssertTrue(mode!.copy.lowercased().contains("connections only"),
                      "skipped-everything states 'Monitoring device connections only' (04)")
        XCTAssertTrue(mode!.copy.lowercased().contains("settings"),
                      "and names the Settings path")
    }

    // MARK: - render bridge reuses N10's OnboardingView surface

    func testRenderStateBridgesToN10OnboardingState() {
        let (sm, _, _, _, _) = machine()
        sm.getStarted()
        let render = sm.state.asRenderState()   // maps to N10's OnboardingState
        XCTAssertEqual(render.steps.map(\.step), [.welcome, .inputMonitoring, .systemExtension, .scanner])
        XCTAssertTrue(render.steps.allSatisfy(\.showsSkip))
        XCTAssertEqual(render.currentIndex, 1)
    }
}
