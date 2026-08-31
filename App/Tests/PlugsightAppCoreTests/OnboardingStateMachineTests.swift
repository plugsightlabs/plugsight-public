// OnboardingStateMachineTests.swift
//
// N11: the PURE step state machine (04 "Onboarding window" + stories 1a-1e).
// Driven entirely through FAKE permission drivers, so every transition is
// deterministic and CI-testable without TCC, SMAppService, the system
// extension, or being in /Applications. The REAL macOS drivers are thin and
// unit-untestable by design; this suite proves the LOGIC that drives them.
//
// Covered: the grant request actually asks the OS (not just a probe); every
// waiting state times out into needsAttention guidance with a real retry (no
// step spins forever); the extension step is honest when no extension is
// bundled; the scanner step gates on daemon-reported ClamAV availability (not
// an FDA heuristic); denial -> degraded consequence copy; Skip is available at
// EVERY step and never punished; the /Applications location check (1d) gates
// the extension step; completion copy is honest for every combination.

import XCTest
@testable import PlugsightAppCore

final class OnboardingStateMachineTests: XCTestCase {

    // MARK: - fixtures

    private struct Fixture {
        let sm: OnboardingStateMachine
        let probe: FakePermissionProbing
        let activator: FakeExtensionActivating
        let login: FakeLoginItemRegistering
        let location: FakeAppLocationChecking
        let scanner: FakeScannerAvailability
        let clock: FakeClock
    }

    private func makeMachine(
        inputMonitoring: Bool = false,
        grantOnRequest: Bool = false,
        extensionActive: Bool = false,
        bundled: Bool = true,
        scannerAvailable: Bool = false,
        inApplications: Bool = true,
        waitTimeout: TimeInterval = 30
    ) -> Fixture {
        let probe = FakePermissionProbing()
        probe.inputMonitoring = inputMonitoring
        probe.grantOnRequest = grantOnRequest
        let activator = FakeExtensionActivating()
        activator.active = extensionActive
        activator.bundled = bundled
        let login = FakeLoginItemRegistering()
        let location = FakeAppLocationChecking()
        location.inApplications = inApplications
        let scanner = FakeScannerAvailability(available: scannerAvailable)
        let clock = FakeClock()
        let sm = OnboardingStateMachine(
            probe: probe, activator: activator, loginItem: login, location: location,
            scanner: scanner, now: { clock.now() }, waitTimeout: waitTimeout)
        return Fixture(sm: sm, probe: probe, activator: activator, login: login,
                       location: location, scanner: scanner, clock: clock)
    }

    /// Assert the copy rule: no em dashes in any user-facing string.
    private func assertNoEmDash(_ s: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(s.contains("\u{2014}"), "user-facing copy must not contain an em dash: \(s)",
                       file: file, line: line)
    }

    private func guidance(_ status: StepStatus, file: StaticString = #file,
                          line: UInt = #line) -> OnboardingStateMachine.Guidance? {
        guard case let .needsAttention(g) = status else {
            XCTFail("expected needsAttention, got \(status)", file: file, line: line)
            return nil
        }
        return g
    }

    // MARK: - shape

    func testStartsAtWelcomeWithFourStepsInOrder() {
        let f = makeMachine()
        XCTAssertEqual(f.sm.state.steps.map(\.kind),
                       [.welcome, .inputMonitoring, .systemExtension, .scanner])
        XCTAssertEqual(f.sm.state.currentIndex, 0)
        XCTAssertEqual(f.sm.state.currentStep.kind, .welcome)
        XCTAssertNil(f.sm.state.resultingMode)
    }

    func testGetStartedRegistersLoginItemAndAdvances() {
        let f = makeMachine()
        f.sm.getStarted()
        XCTAssertEqual(f.login.registrations, 1, "Get started should register the agent login item")
        XCTAssertEqual(f.sm.state.currentStep.kind, .inputMonitoring)
        XCTAssertNil(f.sm.loginItemWarning)
    }

    func testLoginItemFailureIsSurfacedNotSwallowed() {
        let f = makeMachine()
        f.login.errorToThrow = NSError(domain: "sm", code: 1)
        f.sm.getStarted()
        let warning = f.sm.loginItemWarning
        XCTAssertNotNil(warning, "a failed login-item registration must surface a warning")
        XCTAssertTrue(warning!.lowercased().contains("menu"),
                      "the warning names the menu recovery path")
        assertNoEmDash(warning!)
        XCTAssertEqual(f.sm.state.currentStep.kind, .inputMonitoring,
                       "the walk still advances; the failure is a warning, not a wall")
    }

    // MARK: - Input Monitoring: the grant actually asks the OS

    func testGrantRequestsOSPromptWhenNotGranted() {
        let f = makeMachine(inputMonitoring: false, grantOnRequest: false)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        XCTAssertEqual(f.probe.requestCount, 1,
                       "Grant must drive the OS request (CGRequestListenEventAccess), not just re-probe")
        guard case .waitingForSystemSettings = f.sm.state.step(.inputMonitoring).status else {
            return XCTFail("expected waitingForSystemSettings after a declined immediate request")
        }
    }

    func testGrantRequestThatSucceedsLandsImmediately() {
        let f = makeMachine(inputMonitoring: false, grantOnRequest: true)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        XCTAssertEqual(f.probe.requestCount, 1)
        XCTAssertEqual(f.sm.state.step(.inputMonitoring).status, .granted)
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension)
    }

    func testAlreadyGrantedCompletesWithoutRequesting() {
        let f = makeMachine(inputMonitoring: true)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        XCTAssertEqual(f.probe.requestCount, 0, "no OS prompt when the grant is already there")
        XCTAssertEqual(f.sm.state.step(.inputMonitoring).status, .granted)
    }

    func testPendingGrantMovesToWaitingThenGrantLandsOnPoll() {
        let f = makeMachine(inputMonitoring: false)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        guard case .waitingForSystemSettings = f.sm.state.step(.inputMonitoring).status else {
            return XCTFail("expected waiting")
        }
        XCTAssertEqual(f.sm.state.currentStep.kind, .inputMonitoring, "still on the step while waiting")
        f.probe.inputMonitoring = true
        f.sm.poll()
        XCTAssertEqual(f.sm.state.step(.inputMonitoring).status, .granted)
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension, "landed grant advances")
    }

    // MARK: - waiting never spins forever

    func testWaitingTimesOutIntoNeedsAttentionWithRelaunchGuidance() {
        let f = makeMachine(waitTimeout: 30)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        f.clock.advance(by: 30)
        f.sm.poll()
        guard let g = guidance(f.sm.state.step(.inputMonitoring).status) else { return }
        XCTAssertTrue(g.offerRelaunch, "IM timeout guidance offers a relaunch (TCC grants apply on relaunch)")
        XCTAssertEqual(g.deepLink?.url,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertTrue(g.steps.contains("Input Monitoring"), "guidance names the pane")
        XCTAssertTrue(g.steps.contains("System Settings"), "guidance names where to go")
        assertNoEmDash(g.headline)
        assertNoEmDash(g.steps)
        XCTAssertNil(g.terminalCommand)
    }

    func testWaitingBeforeTimeoutStaysWaiting() {
        let f = makeMachine(waitTimeout: 30)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        f.clock.advance(by: 29)
        f.sm.poll()
        guard case .waitingForSystemSettings = f.sm.state.step(.inputMonitoring).status else {
            return XCTFail("must not escalate before the timeout elapses")
        }
    }

    func testRetryAfterTimeoutReRequestsAndResetsTheClock() {
        let f = makeMachine(waitTimeout: 30)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        f.clock.advance(by: 30)
        f.sm.poll()
        XCTAssertNotNil(guidance(f.sm.state.step(.inputMonitoring).status))

        f.sm.requestCurrentGrant()   // Try again
        XCTAssertEqual(f.probe.requestCount, 2, "retry re-drives the OS request")
        guard case let .waitingForSystemSettings(since) = f.sm.state.step(.inputMonitoring).status else {
            return XCTFail("retry returns to waiting")
        }
        XCTAssertEqual(since, f.clock.now(), "the waiting clock resets on retry")
        f.clock.advance(by: 29)
        f.sm.poll()
        guard case .waitingForSystemSettings = f.sm.state.step(.inputMonitoring).status else {
            return XCTFail("the reset clock means no escalation 29s after the retry")
        }
        f.clock.advance(by: 1)
        f.sm.poll()
        XCTAssertNotNil(guidance(f.sm.state.step(.inputMonitoring).status))
    }

    func testLateGrantStillLandsAfterTimeout() {
        let f = makeMachine(waitTimeout: 30)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        f.clock.advance(by: 60)
        f.sm.poll()
        XCTAssertNotNil(guidance(f.sm.state.step(.inputMonitoring).status))
        f.probe.inputMonitoring = true
        f.sm.poll()
        XCTAssertEqual(f.sm.state.step(.inputMonitoring).status, .granted,
                       "polling continues in needsAttention; a late grant still lands")
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension)
    }

    // MARK: - extension step honesty (no bundled extension)

    func testExtensionStepIsHonestWhenNoExtensionBundled() {
        let f = makeMachine(bundled: false)
        f.sm.getStarted()
        f.sm.skipCurrent()   // -> System Extension
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension)
        f.sm.requestCurrentGrant()
        XCTAssertEqual(f.activator.activationRequests, 0,
                       "no activation may be attempted when no extension is bundled")
        guard case let .unavailableInThisBuild(reason) = f.sm.state.step(.systemExtension).status else {
            return XCTFail("expected unavailableInThisBuild")
        }
        XCTAssertTrue(reason.lowercased().contains("does not include"),
                      "the reason is honest about the build")
        assertNoEmDash(reason)
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension, "stays until acknowledged")

        f.sm.acknowledgeUnavailable()
        XCTAssertEqual(f.sm.state.currentStep.kind, .scanner, "Continue advances")
        guard case .unavailableInThisBuild = f.sm.state.step(.systemExtension).status else {
            return XCTFail("the honest status is preserved after acknowledging")
        }
    }

    func testResultingModeTreatsUnavailableExtensionHonestly() {
        let f = makeMachine(inputMonitoring: true, bundled: false, scannerAvailable: true)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()        // IM granted
        f.sm.requestCurrentGrant()        // extension -> unavailableInThisBuild
        f.sm.acknowledgeUnavailable()     // Continue
        f.sm.requestCurrentGrant()        // scanner available -> completes
        let mode = f.sm.state.resultingMode
        XCTAssertEqual(mode?.outcome, .degraded, "an unavailable extension is NOT counted as granted")
        XCTAssertTrue(mode!.copy.contains("the system extension"),
                      "completion copy stays honest and names the extension")
        assertNoEmDash(mode!.copy)
    }

    // MARK: - extension activation errors + timeout

    func testExtensionActivationErrorSurfacesAsNeedsAttention() {
        let f = makeMachine()
        f.sm.getStarted()
        f.sm.skipCurrent()             // -> System Extension
        f.sm.requestCurrentGrant()     // drives activation, waits
        XCTAssertEqual(f.activator.activationRequests, 1)
        f.activator.errorToReport = "The operation could not be completed. (OSSystemExtensionErrorDomain error 1.)"
        f.sm.poll()
        guard let g = guidance(f.sm.state.step(.systemExtension).status) else { return }
        XCTAssertTrue(g.steps.contains("OSSystemExtensionErrorDomain error 1"),
                      "the REAL error text is surfaced, not swallowed")
        XCTAssertEqual(g.deepLink?.url,
                       "x-apple.systempreferences:com.apple.preference.security?Security")
        XCTAssertFalse(g.offerRelaunch)
        assertNoEmDash(g.headline)
        assertNoEmDash(g.steps)
    }

    func testExtensionWaitingTimesOutIntoGuidance() {
        let f = makeMachine(waitTimeout: 30)
        f.sm.getStarted()
        f.sm.skipCurrent()
        f.sm.requestCurrentGrant()
        f.clock.advance(by: 30)
        f.sm.poll()
        guard let g = guidance(f.sm.state.step(.systemExtension).status) else { return }
        XCTAssertFalse(g.offerRelaunch, "extension timeout guidance does not offer a relaunch")
        XCTAssertEqual(g.deepLink?.url,
                       "x-apple.systempreferences:com.apple.preference.security?Security")
        assertNoEmDash(g.headline)
        assertNoEmDash(g.steps)
    }

    func testExtensionLateApprovalStillLandsAfterTimeout() {
        let f = makeMachine(waitTimeout: 30)
        f.sm.getStarted()
        f.sm.skipCurrent()
        f.sm.requestCurrentGrant()
        f.clock.advance(by: 31)
        f.sm.poll()
        XCTAssertNotNil(guidance(f.sm.state.step(.systemExtension).status))
        f.activator.active = true
        f.sm.poll()
        XCTAssertEqual(f.sm.state.step(.systemExtension).status, .granted)
    }

    // MARK: - scanner step gates on daemon-reported availability, not FDA

    func testScannerStepGatesOnScannerAvailabilityNotFDA() {
        let f = makeMachine(scannerAvailable: true)
        f.sm.getStarted()
        f.sm.skipCurrent()   // IM
        f.sm.skipCurrent()   // extension -> scanner
        XCTAssertEqual(f.sm.state.currentStep.kind, .scanner)
        f.sm.requestCurrentGrant()
        XCTAssertEqual(f.sm.state.step(.scanner).status, .granted,
                       "the scanner step completes when the daemon reports ClamAV available")
        XCTAssertNotNil(f.sm.state.resultingMode)
    }

    // WP2: an absent scanner is an explain-and-OFFER, not immediate guidance and
    // never a bare spinner. The pure "Check again"/land call is a no-op while
    // absent (the offer stays); the async install is driven from the controller.
    func testScannerUnavailableStaysAnInstallOfferNotGuidance() {
        let f = makeMachine(scannerAvailable: false)
        f.sm.getStarted()
        f.sm.skipCurrent()
        f.sm.skipCurrent()
        XCTAssertEqual(f.sm.state.currentStep.kind, .scanner)
        f.sm.requestCurrentGrant()   // no scanner present: lands nothing, offer stays
        XCTAssertEqual(f.sm.state.step(.scanner).status, .pending,
                       "an absent scanner keeps the Install offer, not a spinner or guidance")
        if case .waitingForSystemSettings = f.sm.state.step(.scanner).status {
            return XCTFail("scanner absence must not present as a bare waiting state")
        }
        XCTAssertNil(f.sm.state.resultingMode)
    }

    // WP2: accepted install -> installing state (live spinner + detail), which the
    // heartbeat's poll refreshes; installState done (or available) lands the step.
    func testScannerInstallingLandsWhenDaemonReportsDone() {
        let f = makeMachine(scannerAvailable: false)
        f.sm.getStarted(); f.sm.skipCurrent(); f.sm.skipCurrent()
        f.sm.markScannerInstalling(detail: nil)
        guard case .installingScanner = f.sm.state.step(.scanner).status else {
            return XCTFail("accepted install must enter the installing state")
        }
        // Daemon reports progress; poll surfaces the live detail.
        f.scanner.installState = .installing
        f.scanner.installDetail = "Downloading clamav..."
        f.sm.poll()
        guard case let .installingScanner(_, detail) = f.sm.state.step(.scanner).status else {
            return XCTFail("installing state must persist while the daemon installs")
        }
        XCTAssertEqual(detail, "Downloading clamav...")
        // Install finishes.
        f.scanner.installState = .done
        f.sm.poll()
        XCTAssertEqual(f.sm.state.step(.scanner).status, .granted)
        XCTAssertNotNil(f.sm.state.resultingMode, "the last step landing completes the walk")
    }

    // WP2: install rejected (accepted:false) -> the daemon reason plus the honest
    // Terminal fallback, never a dead end. Skip stays.
    func testScannerInstallRejectedShowsReasonAndTerminalFallback() {
        let f = makeMachine(scannerAvailable: false)
        f.sm.getStarted(); f.sm.skipCurrent(); f.sm.skipCurrent()
        f.sm.markScannerInstallRejected(reason: "Homebrew is not installed.")
        guard let g = guidance(f.sm.state.step(.scanner).status) else { return }
        XCTAssertTrue(g.steps.contains("Homebrew is not installed."),
                      "the daemon's reason is surfaced")
        XCTAssertEqual(g.terminalCommand, SettingsViewModel.scannerInstallCommand,
                       "single source: the exact install command the Terminal fallback runs")
        XCTAssertNil(g.deepLink, "no System Settings pane installs a scanner")
        XCTAssertFalse(g.offerRelaunch)
        assertNoEmDash(g.headline); assertNoEmDash(g.steps)
        XCTAssertTrue(f.sm.skipAvailable, "Skip stays available after a rejected install")
    }

    // WP2: install started but installState:failed -> failed guidance with the
    // error tail + Terminal fallback + retry. Skip stays.
    func testScannerInstallFailedShowsGuidanceWithTerminalFallback() {
        let f = makeMachine(scannerAvailable: false)
        f.sm.getStarted(); f.sm.skipCurrent(); f.sm.skipCurrent()
        f.sm.markScannerInstalling(detail: nil)
        f.scanner.installState = .failed
        f.scanner.installDetail = "brew exited with code 1"
        f.sm.poll()
        guard let g = guidance(f.sm.state.step(.scanner).status) else { return }
        XCTAssertTrue(g.steps.contains("brew exited with code 1"), "the error tail is surfaced")
        XCTAssertEqual(g.terminalCommand, SettingsViewModel.scannerInstallCommand)
        XCTAssertFalse(g.offerRelaunch)
        assertNoEmDash(g.headline); assertNoEmDash(g.steps)
        XCTAssertTrue(f.sm.skipAvailable)
    }

    // WP2 fail-safe: an install that never gets picked up by the daemon within the
    // timeout escalates to the Terminal fallback instead of spinning forever.
    func testScannerInstallingEscalatesIfDaemonNeverPicksItUp() {
        let f = makeMachine(scannerAvailable: false, waitTimeout: 30)
        f.sm.getStarted(); f.sm.skipCurrent(); f.sm.skipCurrent()
        f.sm.markScannerInstalling(detail: nil)
        f.scanner.installState = .idle    // daemon never reports installing
        f.clock.advance(by: 30)
        f.sm.poll()
        XCTAssertNotNil(guidance(f.sm.state.step(.scanner).status),
                        "a stuck install must escalate to guidance, never spin forever")
    }

    func testScannerPollLandsWhenDaemonReportsAvailable() {
        let f = makeMachine(scannerAvailable: false)
        f.sm.getStarted()
        f.sm.skipCurrent()
        f.sm.skipCurrent()
        f.sm.requestCurrentGrant()   // absent: offer stays (no-op)
        f.scanner.available = true   // brew install clamav finished; daemon reports it
        f.sm.poll()
        XCTAssertEqual(f.sm.state.step(.scanner).status, .granted)
        XCTAssertNotNil(f.sm.state.resultingMode, "the last step landing completes the walk")
    }

    // WP3: a FAILED install must win over bare availability. A fresh brew ClamAV
    // can leave the binary present (available == true) with zero definitions, so
    // an install that ended failed must NOT land the step green; it shows the
    // failure guidance with the Terminal fallback, and Skip stays.
    func testFailedInstallWinsOverAvailabilityAndDoesNotLand() {
        let scanner = FakeScannerAvailability(available: true, installState: .failed,
                                              installDetail: "freshclam exited with code 1")
        let sm = OnboardingStateMachine(
            probe: FakePermissionProbing(), activator: FakeExtensionActivating(),
            loginItem: FakeLoginItemRegistering(), location: FakeAppLocationChecking(),
            scanner: scanner)
        sm.getStarted(); sm.skipCurrent(); sm.skipCurrent()
        XCTAssertEqual(sm.state.currentStep.kind, .scanner)

        // "Check again" must NOT land the step even though available == true.
        sm.requestCurrentGrant()
        XCTAssertNotEqual(sm.state.step(.scanner).status, .granted,
                          "a failed install must not land green over a defs-less binary")
        XCTAssertNil(sm.state.resultingMode, "the walk must not complete on a failed scanner")

        // The heartbeat poll surfaces the failure guidance + Terminal fallback.
        sm.poll()
        guard let g = guidance(sm.state.step(.scanner).status) else { return }
        XCTAssertTrue(g.steps.contains("freshclam exited with code 1"), "the error tail is surfaced")
        XCTAssertEqual(g.terminalCommand, SettingsViewModel.scannerInstallCommand)
        assertNoEmDash(g.headline); assertNoEmDash(g.steps)
        XCTAssertTrue(sm.skipAvailable, "Skip stays available after a failed install")
    }

    // WP3 counterpart: a user who already had a working scanner before onboarding
    // (installState == idle, available == true) STILL lands green. Only `failed`
    // overrides availability.
    func testIdleAndAvailableStillLandsGreen() {
        let scanner = FakeScannerAvailability(available: true, installState: .idle)
        let sm = OnboardingStateMachine(
            probe: FakePermissionProbing(), activator: FakeExtensionActivating(),
            loginItem: FakeLoginItemRegistering(), location: FakeAppLocationChecking(),
            scanner: scanner)
        sm.getStarted(); sm.skipCurrent(); sm.skipCurrent()
        XCTAssertEqual(sm.state.currentStep.kind, .scanner)
        sm.requestCurrentGrant()
        XCTAssertEqual(sm.state.step(.scanner).status, .granted,
                       "an already-working scanner (idle + available) must still land")
        XCTAssertNotNil(sm.state.resultingMode)
    }

    // WP3b: the timing hole the critic exposed. During a one-click install,
    // `brew install clamav` makes the BINARY present (available == true) BEFORE
    // freshclam runs, while installState stays `.installing` for the whole
    // download. Bare availability must NOT land the step mid-install, or the walk
    // completes as "monitoring active" over a scanner with ZERO virus definitions
    // and a later freshclam failure is never shown. Only a real `.done` lands.
    func testInstallingWithBinaryPresentDoesNotLandUntilDone() {
        let scanner = FakeScannerAvailability(available: true, installState: .installing,
                                              installDetail: "Downloading clamav...")
        let sm = OnboardingStateMachine(
            probe: FakePermissionProbing(), activator: FakeExtensionActivating(),
            loginItem: FakeLoginItemRegistering(), location: FakeAppLocationChecking(),
            scanner: scanner)
        sm.getStarted(); sm.skipCurrent(); sm.skipCurrent()
        XCTAssertEqual(sm.state.currentStep.kind, .scanner)

        // "Check again" must NOT land the step even though available == true:
        // the binary exists but freshclam is still running (no definitions yet).
        sm.requestCurrentGrant()
        XCTAssertNotEqual(sm.state.step(.scanner).status, .granted,
                          "bare availability must not land the step while an install is in progress")
        XCTAssertNil(sm.state.resultingMode, "the walk must not complete mid-install")

        // The heartbeat poll keeps the live installing state, never landing green.
        sm.poll()
        guard case .installingScanner = sm.state.step(.scanner).status else {
            return XCTFail("mid-install must stay in the installing state, not land green")
        }
        XCTAssertNil(sm.state.resultingMode)

        // freshclam finishes: the daemon reports done and only NOW the step lands.
        scanner.installState = .done
        sm.poll()
        XCTAssertEqual(sm.state.step(.scanner).status, .granted,
                       "a real .done lands the step green")
        XCTAssertNotNil(sm.state.resultingMode, "the last step landing completes the walk")
    }

    // WP3b sanity: an install that goes installing(+available) -> done lands the
    // scanner exactly once and completes the walk as active (all steps granted
    // requires the earlier steps too; here the earlier steps are granted).
    func testInstallingThenDoneLandsExactlyOnceAndCompletes() {
        let scanner = FakeScannerAvailability(available: false, installState: .installing)
        let sm = OnboardingStateMachine(
            probe: FakePermissionProbing(inputMonitoring: true),
            activator: FakeExtensionActivating(active: true, bundled: true),
            loginItem: FakeLoginItemRegistering(), location: FakeAppLocationChecking(),
            scanner: scanner)
        sm.getStarted()
        sm.requestCurrentGrant()   // input monitoring already granted -> lands
        sm.requestCurrentGrant()   // extension already active -> lands
        XCTAssertEqual(sm.state.currentStep.kind, .scanner)

        // The binary appears while freshclam still runs: must not land yet.
        scanner.available = true
        sm.poll()
        guard case .installingScanner = sm.state.step(.scanner).status else {
            return XCTFail("installing(+available) must stay installing, not land")
        }
        XCTAssertNil(sm.state.resultingMode)

        // Install finishes: lands green exactly once and completes the walk active.
        scanner.installState = .done
        sm.poll()
        XCTAssertEqual(sm.state.step(.scanner).status, .granted)
        XCTAssertEqual(sm.state.resultingMode?.outcome, .active,
                       "all steps granted completes the walk as active")
    }

    // MARK: - denial -> degraded copy + deep link

    func testDenialProducesDegradedConsequenceCopyAndDeepLink() {
        let f = makeMachine()
        f.sm.getStarted()
        f.sm.denyCurrent()
        guard case let .denied(consequence, link) = f.sm.state.step(.inputMonitoring).status else {
            return XCTFail("expected denied")
        }
        XCTAssertFalse(consequence.isEmpty, "degraded consequence copy present")
        XCTAssertTrue(consequence.lowercased().contains("typing"),
                      "IM denial names the honest consequence (1b)")
        XCTAssertEqual(link?.url.hasPrefix("x-apple.systempreferences:"), true,
                       "deep link points at System Settings")
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension, "denial is not a wall; it advances")
    }

    func testDegradedConsequencesArePresentAndScannerHasNoDeepLink() {
        for kind in [OnboardingStepKind.inputMonitoring, .systemExtension] {
            let pair = OnboardingStateMachine.degradedConsequence(for: kind)
            XCTAssertNotNil(pair, "\(kind) has a degraded consequence")
            XCTAssertFalse(pair!.copy.isEmpty)
            XCTAssertEqual(pair!.deepLink?.url.hasPrefix("x-apple.systempreferences:"), true)
        }
        let scanner = OnboardingStateMachine.degradedConsequence(for: .scanner)
        XCTAssertNotNil(scanner)
        XCTAssertNil(scanner!.deepLink,
                     "no System Settings pane installs a scanner; the deep link is gone with the FDA gate")
        XCTAssertNil(OnboardingStateMachine.degradedConsequence(for: .welcome))
    }

    // MARK: - Skip is always available and never punished

    func testSkipIsAvailableAtEveryStepAndAdvances() {
        let f = makeMachine()
        for _ in 0..<4 {
            XCTAssertTrue(f.sm.skipAvailable, "Skip is available at \(f.sm.state.currentStep.kind)")
            f.sm.skipCurrent()
        }
        XCTAssertNotNil(f.sm.state.resultingMode)
    }

    func testSkipMarksTheStepSkippedNotDenied() {
        let f = makeMachine()
        f.sm.getStarted()
        f.sm.skipCurrent()
        XCTAssertEqual(f.sm.state.step(.inputMonitoring).status, .skipped)
    }

    func testSkipAvailableEvenWhileWaitingOrNeedingAttention() {
        let f = makeMachine(waitTimeout: 30)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()   // -> waiting
        XCTAssertTrue(f.sm.skipAvailable)
        f.clock.advance(by: 31)
        f.sm.poll()                  // -> needsAttention
        XCTAssertTrue(f.sm.skipAvailable, "Skip stays available in needsAttention")
        f.sm.skipCurrent()
        XCTAssertEqual(f.sm.state.step(.inputMonitoring).status, .skipped)
    }

    // MARK: - location check (1d) gates the extension step

    func testWrongLocationShowsMoveInstructionBeforeActivationIsAttempted() {
        let f = makeMachine(inApplications: false)
        f.location.moveInstruction = "Move Plugsight to Applications, then reopen it."
        f.sm.getStarted()
        f.sm.skipCurrent()
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension)
        f.sm.requestCurrentGrant()
        XCTAssertEqual(f.activator.activationRequests, 0,
                       "activation MUST NOT be attempted from the wrong location (1d)")
        XCTAssertEqual(f.sm.state.step(.systemExtension).locationInstruction,
                       "Move Plugsight to Applications, then reopen it.")
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension, "stays on the step until moved")
        XCTAssertEqual(f.sm.state.step(.systemExtension).status, .pending)
    }

    func testCorrectLocationAllowsActivationToBeDriven() {
        let f = makeMachine(inApplications: true)
        f.sm.getStarted(); f.sm.skipCurrent()
        f.sm.requestCurrentGrant()
        XCTAssertEqual(f.activator.activationRequests, 1, "activation is driven when in /Applications")
        guard case .waitingForSystemSettings = f.sm.state.step(.systemExtension).status else {
            return XCTFail("expected waiting")
        }
        XCTAssertNil(f.sm.state.step(.systemExtension).locationInstruction)
    }

    // MARK: - completion copy is honest for every combination

    func testCompletionAllGrantedIsActiveAndHonest() {
        let f = makeMachine(inputMonitoring: true, extensionActive: true, scannerAvailable: true)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()  // IM granted
        f.sm.requestCurrentGrant()  // extension active
        f.sm.requestCurrentGrant()  // scanner available -> completes
        let mode = f.sm.state.resultingMode
        XCTAssertEqual(mode?.outcome, .active)
        XCTAssertTrue(mode!.copy.lowercased().contains("active"))
    }

    func testCompletionSomeDeniedIsDegradedAndNamesTheMissingGrant() {
        let f = makeMachine(inputMonitoring: false, extensionActive: true, scannerAvailable: true)
        f.sm.getStarted()
        f.sm.denyCurrent()          // deny Input Monitoring
        f.sm.requestCurrentGrant()  // extension active -> granted
        f.sm.requestCurrentGrant()  // scanner -> granted, completes
        let mode = f.sm.state.resultingMode
        XCTAssertEqual(mode?.outcome, .degraded)
        XCTAssertTrue(mode!.copy.contains("Input Monitoring"),
                      "degraded copy names the recognizable missing grant (04)")
    }

    func testCompletionAllSkippedIsConnectionsOnly() {
        let f = makeMachine()
        f.sm.skipCurrent(); f.sm.skipCurrent(); f.sm.skipCurrent(); f.sm.skipCurrent()
        let mode = f.sm.state.resultingMode
        XCTAssertEqual(mode?.outcome, .connectionsOnly)
        XCTAssertTrue(mode!.copy.lowercased().contains("connections only"))
        XCTAssertTrue(mode!.copy.lowercased().contains("settings"))
    }

    // MARK: - render bridge reuses N10's OnboardingView surface

    func testRenderStateBridgesToN10OnboardingState() {
        let f = makeMachine()
        f.sm.getStarted()
        let render = f.sm.state.asRenderState(now: f.clock.now())
        XCTAssertEqual(render.steps.map(\.step), [.welcome, .inputMonitoring, .systemExtension, .scanner])
        XCTAssertTrue(render.steps.allSatisfy(\.showsSkip))
        XCTAssertEqual(render.currentIndex, 1)
    }

    func testBridgeDoesNotCollapseDeniedIntoNotGranted() {
        let f = makeMachine()
        f.sm.getStarted()
        f.sm.denyCurrent()
        let render = f.sm.state.asRenderState(now: f.clock.now())
        guard case let .denied(consequence) = render.steps[1].grant else {
            return XCTFail("a denied step must render as denied, not notGranted")
        }
        XCTAssertTrue(consequence.lowercased().contains("typing"))
    }

    func testBridgeComputesElapsedWaitingSecondsDeterministically() {
        let f = makeMachine()
        f.sm.getStarted()
        f.sm.requestCurrentGrant()   // -> waiting(since: t0)
        f.clock.advance(by: 12)
        let render = f.sm.state.asRenderState(now: f.clock.now())
        XCTAssertEqual(render.steps[1].grant, .waiting(elapsedSeconds: 12))
    }

    func testBridgeMapsNeedsAttentionThrough() {
        let f = makeMachine(waitTimeout: 30)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()
        f.clock.advance(by: 30)
        f.sm.poll()
        let render = f.sm.state.asRenderState(now: f.clock.now())
        guard case let .needsAttention(headline, steps, terminalCommand, showRelaunch) = render.steps[1].grant else {
            return XCTFail("needsAttention must map through to the render surface")
        }
        XCTAssertFalse(headline.isEmpty)
        XCTAssertTrue(steps.contains("System Settings"))
        XCTAssertNil(terminalCommand)
        XCTAssertTrue(showRelaunch)
    }

    func testBridgeMapsUnavailableThrough() {
        let f = makeMachine(bundled: false)
        f.sm.getStarted()
        f.sm.skipCurrent()
        f.sm.requestCurrentGrant()   // -> unavailableInThisBuild
        let render = f.sm.state.asRenderState(now: f.clock.now())
        guard case let .unavailable(reason) = render.steps[2].grant else {
            return XCTFail("unavailableInThisBuild must map through to the render surface")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testBridgeScannerStepHasNoSettingsLink() {
        let f = makeMachine(scannerAvailable: false)
        f.sm.getStarted()
        f.sm.skipCurrent()
        f.sm.skipCurrent()           // -> scanner
        let render = f.sm.state.asRenderState(now: f.clock.now())
        XCTAssertNil(render.currentStepSettingsLink,
                     "the scanner step's recovery is Terminal, not a System Settings pane")
    }

    // MARK: - primary-button render decision (regression: no dead end at the last step)

    /// Regression: a SUCCESSFUL ClamAV install used to land the scanner step on a
    /// green "Granted" with a prominent "Try again" primary. A completed walk must
    /// render Done (which closes the window), and Skip disappears with it.
    func testCompletedWalkRendersDonePrimaryAndHidesSkip() {
        let f = makeMachine(inputMonitoring: true, extensionActive: true, scannerAvailable: true)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()   // Input Monitoring lands
        f.sm.requestCurrentGrant()   // extension lands
        f.sm.requestCurrentGrant()   // scanner lands -> walk complete
        XCTAssertTrue(f.sm.state.isComplete)
        let render = f.sm.state.asRenderState(now: f.clock.now())
        let current = render.steps[render.currentIndex]
        XCTAssertEqual(current.grant, .granted)
        XCTAssertEqual(render.primaryAction(for: current), .done)
        XCTAssertFalse(current.showsSkip, "Skip has nothing left to skip once the walk is complete")
    }

    /// A walk finished by skipping the last step is just as complete: Done, not a
    /// live "Install ClamAV" under the completion copy.
    func testWalkCompletedBySkippingLastStepAlsoRendersDone() {
        let f = makeMachine()
        f.sm.getStarted()
        f.sm.skipCurrent(); f.sm.skipCurrent(); f.sm.skipCurrent()
        XCTAssertTrue(f.sm.state.isComplete)
        let render = f.sm.state.asRenderState(now: f.clock.now())
        XCTAssertEqual(render.primaryAction(for: render.steps[render.currentIndex]), .done)
    }

    /// Mid-walk the scanner step keeps its WP2 primaries: the offer is
    /// "Install ClamAV", installing has no primary, and a failure is "Try again".
    func testScannerPrimariesMidWalkAreUnchanged() {
        let f = makeMachine(scannerAvailable: false)
        f.sm.getStarted()
        f.sm.skipCurrent(); f.sm.skipCurrent()           // -> scanner, pending
        var render = f.sm.state.asRenderState(now: f.clock.now())
        XCTAssertEqual(render.primaryAction(for: render.steps[render.currentIndex]), .installScanner)

        f.sm.markScannerInstalling(detail: nil)
        render = f.sm.state.asRenderState(now: f.clock.now())
        XCTAssertEqual(render.primaryAction(for: render.steps[render.currentIndex]), .none)

        f.scanner.installState = .failed
        f.sm.poll()
        render = f.sm.state.asRenderState(now: f.clock.now())
        XCTAssertEqual(render.primaryAction(for: render.steps[render.currentIndex]), .tryAgain)
        XCTAssertTrue(render.steps[render.currentIndex].showsSkip, "Skip stays available mid-walk")
    }

    /// Non-final steps never dead-end on a landed grant: the machine advances
    /// past them, so only the LAST step ever renders its own granted state.
    func testLandedNonFinalStepsAutoAdvancePastGranted() {
        let f = makeMachine(inputMonitoring: true, extensionActive: true)
        f.sm.getStarted()
        f.sm.requestCurrentGrant()   // Input Monitoring lands -> auto-advance
        XCTAssertEqual(f.sm.state.currentStep.kind, .systemExtension)
        f.sm.requestCurrentGrant()   // extension lands -> auto-advance
        XCTAssertEqual(f.sm.state.currentStep.kind, .scanner)
        XCTAssertFalse(f.sm.state.isComplete)
        let render = f.sm.state.asRenderState(now: f.clock.now())
        XCTAssertNotEqual(render.primaryAction(for: render.steps[render.currentIndex]), .done)
    }
}
