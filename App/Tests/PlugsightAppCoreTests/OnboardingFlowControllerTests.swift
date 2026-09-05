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
        scanner: ScannerAvailabilityChecking = FakeScannerAvailability(),
        notifications: NotificationPermissionChecking = FakeNotificationPermission(),
        opener: FakeSystemSettingsOpener = FakeSystemSettingsOpener(),
        relauncher: FakeAppRelaunching? = nil,
        installer: ScannerInstalling = FakeScannerInstalling(),
        terminal: TerminalOpening? = nil,
        clock: FakeClock = FakeClock(),
        waitTimeout: TimeInterval = 30,
        onCompleted: @escaping () -> Void = {}
    ) -> OnboardingFlowController {
        let machine = OnboardingStateMachine(
            probe: probe, activator: activator, loginItem: loginItem, location: location,
            scanner: scanner, notifications: notifications,
            now: { clock.now() }, waitTimeout: waitTimeout)
        return OnboardingFlowController(machine: machine, opener: opener,
                                        relauncher: relauncher,
                                        installer: installer, terminal: terminal,
                                        now: { clock.now() }, onCompleted: onCompleted)
    }

    func testInitialRenderStateStartsAtWelcome() {
        let controller = makeController()
        XCTAssertEqual(controller.renderState.currentIndex, 0)
        XCTAssertEqual(controller.renderState.steps.count, 5)
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
        XCTAssertEqual(controller.renderState.steps[1].grant, .waiting(elapsedSeconds: 0))

        probe.inputMonitoring = true  // the grant lands in System Settings
        controller.poll()

        XCTAssertEqual(controller.renderState.steps[1].grant, .granted)
        XCTAssertEqual(controller.renderState.currentIndex, 2)
    }

    func testWaitingStepSurfacesADeepLinkAndOpenSettingsOpensIt() {
        // Input Monitoring not granted -> the step waits, and it MUST offer a
        // real recovery: the render state carries the pane's deep link, and
        // openSettings hands exactly that URL to the opener (1b/1c).
        let opener = FakeSystemSettingsOpener()
        let controller = makeController(probe: FakePermissionProbing(inputMonitoring: false), opener: opener)
        controller.primaryAction()  // welcome -> input monitoring
        controller.primaryAction()  // not granted -> waiting

        let link = controller.renderState.currentStepSettingsLink
        XCTAssertEqual(link?.url, "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")

        controller.openSettings()
        XCTAssertEqual(opener.opened, [link!.url])
    }

    func testCompletedWalkHasNoDeepLinkAndOpenSettingsIsANoop() {
        let opener = FakeSystemSettingsOpener()
        let controller = makeController(opener: opener)
        controller.primaryAction(); controller.skip(); controller.skip(); controller.skip(); controller.skip()
        XCTAssertTrue(controller.isComplete)
        XCTAssertNil(controller.renderState.currentStepSettingsLink)
        controller.openSettings()
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testSkipAdvancesWithoutPunishment() {
        let controller = makeController()
        controller.primaryAction()  // welcome
        controller.skip()           // skip input monitoring
        XCTAssertEqual(controller.renderState.currentIndex, 2)
    }

    // MARK: - notifications step wiring (the OS prompt is actually driven)

    func testNotificationsPrimaryDrivesTheOSPromptAndLandsOnAllow() async {
        let notifications = FakeNotificationPermission(current: .notDetermined,
                                                       answerOnRequest: .authorized)
        let controller = makeController(notifications: notifications)
        controller.primaryAction()          // welcome
        controller.skip()                   // input monitoring
        controller.skip()                   // system extension -> notifications
        await controller.primaryActionAsync()
        XCTAssertEqual(notifications.requestCalls, 1, "the primary must drive the OS prompt")
        XCTAssertEqual(controller.renderState.steps[3].grant, .granted)
    }

    func testNotificationsPromptDenialShowsHonestConsequenceAndAdvances() async {
        let notifications = FakeNotificationPermission(current: .notDetermined,
                                                       answerOnRequest: .denied)
        let controller = makeController(notifications: notifications)
        controller.primaryAction(); controller.skip(); controller.skip()
        await controller.primaryActionAsync()
        guard case .denied = controller.renderState.steps[3].grant else {
            return XCTFail("a prompt denial must render as denied, got \(controller.renderState.steps[3].grant)")
        }
        XCTAssertEqual(controller.renderState.currentIndex, 4, "denial advances to the scanner")
    }

    // MARK: - Heartbeat: the scanner driver is actually refreshed (WP2 blocker)

    func testHeartbeatRefreshesScannerAvailabilityOnTheScannerStep() async {
        // DaemonScannerAvailability only learns anything in refresh(); a heartbeat
        // that never refreshes leaves the scanner step reading a stale `false`
        // forever. The heartbeat MUST drive refresh() before polling.
        let scanner = FakeScannerAvailability(available: false)
        let controller = makeController(scanner: scanner)
        controller.primaryAction()  // welcome
        controller.skip()           // input monitoring
        controller.skip()           // system extension
        controller.skip()           // notifications -> now on scanner

        await controller.heartbeatTick()

        XCTAssertGreaterThan(scanner.refreshCalls, 0,
                             "the heartbeat must refresh the daemon-reported scanner availability")
    }

    func testScannerFlipLandsTheStepThroughTheHeartbeat() async {
        // ClamAV appears (installed out of band) while the step shows the Install
        // offer: the next heartbeat refreshes, sees it, and lands the step.
        let scanner = FakeScannerAvailability(available: false)
        let controller = makeController(scanner: scanner)
        controller.primaryAction()  // welcome
        controller.skip()           // input monitoring
        controller.skip()           // system extension
        controller.skip()           // notifications -> now on scanner (Install offer)
        guard case .undecided = controller.renderState.steps[4].grant else {
            return XCTFail("expected the Install offer, got \(controller.renderState.steps[4].grant)")
        }

        scanner.available = true    // ClamAV present now
        await controller.heartbeatTick()

        XCTAssertEqual(controller.renderState.steps[4].grant, .granted)
        XCTAssertTrue(controller.isComplete)
    }

    // MARK: - WP2 one-click install flow

    func testScannerOfferInstallCallsInstallerAndEntersInstalling() async {
        // Choosing "Install ClamAV" on the offer calls the install driver (spy)
        // and enters the live installing state.
        let scanner = FakeScannerAvailability(available: false)
        let installer = FakeScannerInstalling(result: ScannerInstallResult(accepted: true, reason: nil))
        let controller = makeController(scanner: scanner, installer: installer)
        controller.primaryAction(); controller.skip(); controller.skip(); controller.skip()  // -> scanner offer

        await controller.primaryActionAsync()   // Install ClamAV

        XCTAssertEqual(installer.installCalls, 1, "the install driver must be invoked")
        guard case .installing = controller.renderState.steps[4].grant else {
            return XCTFail("an accepted install must enter the installing state, got \(controller.renderState.steps[4].grant)")
        }
        XCTAssertFalse(controller.isComplete)
    }

    func testAcceptedInstallLandsOnDoneThroughTheHeartbeat() async {
        let scanner = FakeScannerAvailability(available: false)
        let installer = FakeScannerInstalling(result: ScannerInstallResult(accepted: true, reason: nil))
        let controller = makeController(scanner: scanner, installer: installer)
        controller.primaryAction(); controller.skip(); controller.skip(); controller.skip()
        await controller.primaryActionAsync()   // -> installing

        scanner.installState = .installing
        scanner.installDetail = "Installing definitions..."
        await controller.heartbeatTick()
        guard case .installing(let detail) = controller.renderState.steps[4].grant else {
            return XCTFail("expected installing with live detail")
        }
        XCTAssertEqual(detail, "Installing definitions...")

        scanner.installState = .done
        await controller.heartbeatTick()
        XCTAssertEqual(controller.renderState.steps[4].grant, .granted)
        XCTAssertTrue(controller.isComplete)
    }

    func testRejectedInstallShowsGuidanceAndTerminalFallbackNoDeadEnd() async {
        let scanner = FakeScannerAvailability(available: false)
        let installer = FakeScannerInstalling(
            result: ScannerInstallResult(accepted: false, reason: "Homebrew is not installed."))
        let terminal = FakeTerminalOpening()
        let controller = makeController(scanner: scanner, installer: installer, terminal: terminal)
        controller.primaryAction(); controller.skip(); controller.skip(); controller.skip()

        await controller.primaryActionAsync()   // Install ClamAV -> rejected

        guard case let .needsAttention(_, steps, command, _) = controller.renderState.steps[4].grant else {
            return XCTFail("a rejected install must show guidance, got \(controller.renderState.steps[4].grant)")
        }
        XCTAssertTrue(steps.contains("Homebrew is not installed."))
        XCTAssertEqual(command, SettingsViewModel.scannerInstallCommand)

        // The Terminal fallback opens Terminal with the expected command.
        controller.openInstallInTerminal()
        XCTAssertEqual(terminal.commands, [SettingsViewModel.scannerInstallCommand])
        // Skip is still a way out (never a dead end).
        controller.skip()
        XCTAssertTrue(controller.isComplete)
    }

    /// A gated install driver: install() suspends until `release()` is called, so
    /// a test can hold two overlapping install actions in flight at once.
    private final class GatedScannerInstalling: ScannerInstalling, @unchecked Sendable {
        private(set) var installCalls = 0
        private var continuations: [CheckedContinuation<Void, Never>] = []
        // Latch: release() can run before install() reaches its suspension point
        // (the test releases after a single Task.yield(), which does not guarantee
        // the winning task has registered its continuation yet). Without this, a
        // continuation registered after release() would wait forever for a
        // release() that already happened and never comes again, hanging the test.
        // Recording the release makes a later-registered continuation resume at
        // once, so the fake is order-independent.
        private var released = false
        let result: ScannerInstallResult
        init(result: ScannerInstallResult = ScannerInstallResult(accepted: true, reason: nil)) {
            self.result = result
        }
        func install() async -> ScannerInstallResult {
            installCalls += 1
            await withCheckedContinuation { c in
                if released { c.resume() } else { continuations.append(c) }
            }
            return result
        }
        func release() {
            released = true
            let cs = continuations; continuations = []
            for c in cs { c.resume() }
        }
    }

    // WP3 minor D: a double-tap on Install must issue only ONE installer.install().
    // Without the re-entrancy guard both taps reach the daemon; it rejects the
    // second and the late "already running" flashes over the installing state.
    func testDoubleTapInstallIssuesASingleInstall() async {
        let scanner = FakeScannerAvailability(available: false)
        let installer = GatedScannerInstalling()
        let controller = makeController(scanner: scanner, installer: installer)
        controller.primaryAction(); controller.skip(); controller.skip(); controller.skip()  // -> scanner offer

        // Two overlapping install actions (the second while the first is in flight).
        let first = Task { await controller.primaryActionAsync() }
        let second = Task { await controller.primaryActionAsync() }
        await Task.yield()
        installer.release()
        await first.value; await second.value

        XCTAssertEqual(installer.installCalls, 1,
                       "a double-tap must issue exactly one install(), not two")
        guard case .installing = controller.renderState.steps[4].grant else {
            return XCTFail("the step stays in the installing state, got \(controller.renderState.steps[4].grant)")
        }
    }

    // The guard must not block a legitimate retry after a failed install: once the
    // step leaves the installing state, a fresh "Try again" issues a new install().
    func testRetryAfterFailedInstallIssuesAFreshInstall() async {
        let scanner = FakeScannerAvailability(available: false)
        let installer = FakeScannerInstalling(result: ScannerInstallResult(accepted: true, reason: nil))
        let controller = makeController(scanner: scanner, installer: installer)
        controller.primaryAction(); controller.skip(); controller.skip(); controller.skip()
        await controller.primaryActionAsync()   // -> installing (install #1)
        XCTAssertEqual(installer.installCalls, 1)

        // Daemon reports the install failed; the step leaves installing.
        scanner.installState = .failed
        scanner.installDetail = "freshclam exited with code 1"
        await controller.heartbeatTick()
        guard case .needsAttention = controller.renderState.steps[4].grant else {
            return XCTFail("a failed install must show guidance")
        }

        // Try again fires a fresh install rather than being blocked by the guard.
        scanner.installState = .idle
        await controller.primaryActionAsync()   // retry (install #2)
        XCTAssertEqual(installer.installCalls, 2, "a retry after failure must issue a new install")
    }

    func testInstallSkippedFromInstallingStillCompletes() async {
        // Never spin forever with no exit: Skip is available during installing.
        let scanner = FakeScannerAvailability(available: false)
        let controller = makeController(scanner: scanner)
        controller.primaryAction(); controller.skip(); controller.skip(); controller.skip()
        await controller.primaryActionAsync()   // -> installing
        guard case .installing = controller.renderState.steps[4].grant else {
            return XCTFail("expected installing")
        }
        controller.skip()
        XCTAssertTrue(controller.isComplete)
    }

    func testHeartbeatDoesNotHammerTheDaemonBeforeTheScannerStep() async {
        // Refresh is an API round-trip; the welcome/permission steps must not
        // trigger one every second.
        let scanner = FakeScannerAvailability(available: false)
        let controller = makeController(scanner: scanner)

        await controller.heartbeatTick()            // welcome
        controller.primaryAction()
        await controller.heartbeatTick()            // input monitoring

        XCTAssertEqual(scanner.refreshCalls, 0)
    }

    func testOverlappingHeartbeatsRunOnlyOneRefresh() async {
        // The live heartbeat fires every second regardless of whether the last
        // refresh finished; a daemon that accepts the connection but never
        // answers would otherwise queue one refresh per tick. A tick that
        // arrives while a refresh is in flight must skip the refresh.
        let scanner = SuspendingScannerAvailability()
        let controller = makeController(scanner: scanner)
        controller.primaryAction()  // welcome
        controller.skip()           // input monitoring
        controller.skip()           // system extension
        controller.skip()           // notifications -> now on scanner

        let first = Task { await controller.heartbeatTick() }
        await scanner.waitUntilRefreshStarted()

        await controller.heartbeatTick()   // overlaps the suspended refresh

        XCTAssertEqual(scanner.refreshCalls, 1,
                       "a heartbeat overlapping an in-flight refresh must not start another")

        scanner.finishRefresh()
        await first.value
        XCTAssertEqual(scanner.refreshCalls, 1)

        let third = Task { await controller.heartbeatTick() }  // once drained, refreshes resume
        await scanner.waitUntilRefreshStarted()
        XCTAssertEqual(scanner.refreshCalls, 2)
        scanner.finishRefresh()
        await third.value
    }

    // MARK: - "Check again" refreshes before deciding (honest scanner primary)

    func testScannerPrimaryActionRefreshesBeforeDeciding() async {
        // ClamAV is installed but no heartbeat has run yet, so the cached
        // driver value is still false. The explicit gesture must refresh
        // first; deciding on the stale cache would show install guidance on a
        // machine that has the scanner.
        let scanner = RefreshBackedScannerAvailability()
        scanner.daemonReportsAvailable = true   // cached value still false
        let controller = makeController(scanner: scanner)
        controller.primaryAction()  // welcome
        controller.skip()           // input monitoring
        controller.skip()           // system extension
        controller.skip()           // notifications -> now on scanner

        await controller.primaryActionAsync()

        XCTAssertEqual(scanner.refreshCalls, 1,
                       "the scanner primary must refresh before reading availability")
        XCTAssertEqual(controller.renderState.steps[4].grant, .granted)
        XCTAssertTrue(controller.isComplete)
    }

    func testPrimaryActionAsyncStaysSyncEquivalentOffTheScannerStep() async {
        // The async primary is what the view calls for every step; before the
        // scanner step it must not touch the daemon and must behave exactly
        // like the sync path.
        let scanner = RefreshBackedScannerAvailability()
        let loginItem = FakeLoginItemRegistering()
        let controller = makeController(loginItem: loginItem, scanner: scanner)

        await controller.primaryActionAsync()  // welcome -> Get started

        XCTAssertEqual(loginItem.registrations, 1)
        XCTAssertEqual(controller.renderState.currentIndex, 1)
        XCTAssertEqual(scanner.refreshCalls, 0)
    }

    // MARK: - Waiting elapsed seconds tick with the heartbeat

    func testWaitingElapsedSecondsTickWithTheHeartbeat() async {
        let clock = FakeClock()
        let controller = makeController(probe: FakePermissionProbing(inputMonitoring: false),
                                        clock: clock)
        controller.primaryAction()  // welcome -> input monitoring
        controller.primaryAction()  // not granted -> waiting
        XCTAssertEqual(controller.renderState.steps[1].grant, .waiting(elapsedSeconds: 0))

        clock.advance(by: 3)
        await controller.heartbeatTick()

        XCTAssertEqual(controller.renderState.steps[1].grant, .waiting(elapsedSeconds: 3))
    }

    // MARK: - Relaunch wiring

    func testRelaunchDrivesTheRelauncher() {
        let relauncher = FakeAppRelaunching()
        let controller = makeController(relauncher: relauncher)
        controller.relaunch()
        XCTAssertEqual(relauncher.relaunchCalls, 1)
    }

    func testRelaunchIsANoopWithoutARelauncher() {
        let controller = makeController()
        controller.relaunch()  // must not crash (previews/tests wire no relauncher)
    }

    func testCompletionFiresOnceWithHonestCopy() {
        var completions = 0
        let controller = makeController(onCompleted: { completions += 1 })

        controller.primaryAction()  // welcome
        controller.skip()           // input monitoring
        controller.skip()           // system extension
        controller.skip()           // notifications
        controller.skip()           // scanner

        XCTAssertTrue(controller.isComplete)
        XCTAssertNotNil(controller.renderState.completionCopy)
        XCTAssertEqual(completions, 1)

        controller.poll()           // further ticks never re-fire completion
        XCTAssertEqual(completions, 1)
    }
}

/// A scanner fake that mirrors the real DaemonScannerAvailability shape:
/// scannerAvailable() reads a CACHED value that only refresh() updates from
/// what "the daemon" reports. Landing a step with this fake proves the code
/// under test actually refreshed instead of reading a stale cache.
@MainActor
private final class RefreshBackedScannerAvailability: ScannerAvailabilityChecking {
    var daemonReportsAvailable = false
    private var cached = false
    private(set) var refreshCalls = 0

    nonisolated func scannerAvailable() -> Bool {
        MainActor.assumeIsolated { cached }
    }

    func refresh() async {
        refreshCalls += 1
        cached = daemonReportsAvailable
    }
}

/// A scanner fake whose refresh() suspends until the test resumes it, so the
/// re-entrancy tests can hold a refresh "in flight" deterministically.
@MainActor
private final class SuspendingScannerAvailability: ScannerAvailabilityChecking {
    var available = false
    private(set) var refreshCalls = 0
    private var inFlight: CheckedContinuation<Void, Never>?
    private var startObserver: CheckedContinuation<Void, Never>?
    private var refreshesStarted = 0
    private var startsObserved = 0

    nonisolated func scannerAvailable() -> Bool {
        MainActor.assumeIsolated { available }
    }

    func refresh() async {
        refreshCalls += 1
        refreshesStarted += 1
        if let observer = startObserver { startObserver = nil; observer.resume() }
        await withCheckedContinuation { inFlight = $0 }
    }

    /// Suspends until the next refresh() the test has not yet observed begins.
    func waitUntilRefreshStarted() async {
        if refreshesStarted > startsObserved { startsObserved += 1; return }
        await withCheckedContinuation { startObserver = $0 }
        startsObserved += 1
    }

    func finishRefresh() {
        if let c = inFlight { inFlight = nil; c.resume() }
    }
}
