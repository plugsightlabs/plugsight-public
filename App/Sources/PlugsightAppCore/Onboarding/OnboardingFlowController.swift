// OnboardingFlowController.swift
//
// The RUNTIME wiring of N11's pure state machine onto N10's render surface: an
// observable object the live onboarding window binds to. Every user gesture is a
// machine transition followed by a re-projection through asRenderState(), so the
// window renders exactly what the tested machine says and nothing else. The
// completion callback fires ONCE, when the walk finishes, so the host (the app
// shell) can record first-run completion. Fully CI-testable with the fakes in
// Testing/ — no TCC, SMAppService, or window required.

import Combine
import Foundation
import SwiftUI

@MainActor
public final class OnboardingFlowController: ObservableObject {
    @Published public private(set) var renderState: OnboardingState

    private let machine: OnboardingStateMachine
    private let opener: SystemSettingsOpening
    private let relauncher: AppRelaunching?
    /// The one-click ClamAV installer for the scanner step (WP2). The async
    /// install call lives here in the controller layer, like scanner.refresh().
    private let installer: ScannerInstalling
    /// Opens Terminal.app running the install command (WP2 fallback). Optional so
    /// previews/tests that never exercise the fallback can omit it.
    private let terminal: TerminalOpening?
    private let now: () -> Date
    private let onCompleted: () -> Void
    private var completionDelivered = false
    /// Re-entrancy guard for the heartbeat's scanner refresh: the 1s timer
    /// fires regardless of whether the last refresh answered, and the daemon
    /// client can wait up to its full timeout, so overlapping ticks must skip
    /// the refresh instead of queueing one per second.
    private var refreshInFlight = false
    /// Re-entrancy guard for the scanner install action: a double-tap on Install
    /// fires two `runScannerInstall()` calls, and without this both reach
    /// `installer.install()`. The daemon rejects the second and, if that rejection
    /// resolves last, flashes a false "already running" over the installing state.
    /// Set before the first install is issued and held while the install is in
    /// flight; cleared once the machine leaves the installing state (landed,
    /// failed, or rejected) so a legitimate "Try again" can fire.
    private var installTriggered = false

    public init(machine: OnboardingStateMachine, opener: SystemSettingsOpening,
                relauncher: AppRelaunching? = nil,
                installer: ScannerInstalling = FakeScannerInstalling(),
                terminal: TerminalOpening? = nil,
                now: @escaping () -> Date = Date.init,
                onCompleted: @escaping () -> Void = {}) {
        self.machine = machine
        self.opener = opener
        self.relauncher = relauncher
        self.installer = installer
        self.terminal = terminal
        self.now = now
        self.onCompleted = onCompleted
        self.renderState = machine.state.asRenderState(now: now())
    }

    public var isComplete: Bool { machine.state.isComplete }

    /// The step's primary button (Get started / Grant / Activate). "Try again"
    /// on a waiting step is the same transition, so it shares this. Synchronous
    /// and refresh-free, so tests of the non-scanner steps stay deterministic;
    /// the live view calls `primaryActionAsync()` instead, which makes the
    /// scanner step's "Check again" refresh before deciding.
    public func primaryAction() { machine.requestCurrentGrant(); sync() }

    /// The primary gesture as the live view drives it. On the scanner step this is
    /// the WP2 explain-and-offer install: refresh (so an already-installed ClamAV
    /// lands instead of re-installing), then, if still absent, drive the one-click
    /// install. Every other step skips the refresh and behaves exactly like
    /// `primaryAction()`.
    public func primaryActionAsync() async {
        if !machine.state.isComplete, machine.state.currentStep.kind == .scanner {
            await runScannerInstall()
            return
        }
        if !machine.state.isComplete, machine.state.currentStep.kind == .notifications {
            await runNotificationsGrant()
            return
        }
        machine.requestCurrentGrant()
        sync()
    }

    /// Drive the notifications step: refresh (an already-answered permission
    /// lands or records its denial immediately), then ask the OS (the same
    /// explicit prompt NotificationManager makes) and resolve the answer.
    private func runNotificationsGrant() async {
        await machine.notificationsPermission.refresh()
        machine.requestCurrentGrant()
        guard !machine.state.isComplete,
              machine.state.currentStep.kind == .notifications else { sync(); return }
        await machine.notificationsPermission.request()
        machine.poll()
        sync()
    }

    /// Drive the scanner step's one-click ClamAV install (WP2). Refresh first so an
    /// already-present scanner simply lands; otherwise call the daemon's install
    /// and either enter the installing state (accepted) or show the reason plus the
    /// Terminal fallback (rejected). Progress after acceptance is polled by the
    /// heartbeat. Also serves the rejected/failed "Try again".
    private func runScannerInstall() async {
        // Re-entrancy guard (set synchronously, before the first await): a
        // double-tap must issue only ONE installer.install().
        guard !installTriggered else { return }
        installTriggered = true
        await machine.scanner.refresh()
        machine.requestCurrentGrant()      // lands immediately if ClamAV is present
        guard !machine.state.isComplete, machine.state.currentStep.kind == .scanner else {
            installTriggered = false; sync(); return
        }
        let result = await installer.install()
        if result.accepted {
            // Hold the guard while the daemon installs; clearInstallGuardIfSettled
            // drops it once the step leaves the installing state.
            machine.markScannerInstalling(detail: nil)
        } else {
            installTriggered = false       // a rejected start may be retried at once
            machine.markScannerInstallRejected(reason: result.reason)
        }
        sync()
    }

    /// Drop the install re-entrancy guard once the scanner step is no longer
    /// installing (it landed, failed, or the walk completed), so a "Try again"
    /// can issue a fresh install.
    private func clearInstallGuardIfSettled() {
        guard installTriggered else { return }
        if machine.state.isComplete || machine.state.currentStep.kind != .scanner {
            installTriggered = false; return
        }
        if case .installingScanner = machine.state.currentStep.status { return }
        installTriggered = false
    }

    /// Open Terminal.app running the ClamAV install command (WP2 fallback). No-op
    /// when no terminal opener is wired (previews/tests that omit it).
    public func openInstallInTerminal() {
        terminal?.runInTerminal(SettingsViewModel.scannerInstallCommand)
    }

    /// Skip: available on every step, never punished (04).
    public func skip() { machine.skipCurrent(); sync() }

    /// "Open settings": hand the current step's System Settings deep link to the
    /// opener so a not-yet-granted step has a real recovery (1b/1c). No-op on
    /// Welcome / once complete, where there is no link.
    public func openSettings() {
        if let url = renderState.currentStepSettingsLink?.url { opener.open(url) }
    }

    /// Continue past a capability this build does not ship (the extension step's
    /// honest `.unavailable` state).
    public func acknowledgeUnavailable() { machine.acknowledgeUnavailable(); sync() }

    /// Relaunch the app so a grant flipped in System Settings takes effect
    /// (offered by the Input Monitoring needsAttention guidance). No-op when no
    /// relauncher is wired (previews/tests).
    public func relaunch() { relauncher?.relaunch() }

    /// Live re-check while a step waits for System Settings (04: grants land
    /// without another click). Synchronous so tests stay deterministic; the
    /// live window drives `heartbeatTick()` instead, which refreshes first.
    public func poll() { machine.poll(); clearInstallGuardIfSettled(); sync() }

    /// One heartbeat from the hosting view's 1s timer: refresh the async
    /// driver state that poll() reads synchronously, then poll. Without the
    /// refresh, the daemon-backed scanner driver stays at its boot value
    /// forever and the Scanner step can never land. Refresh only runs while
    /// the walk is ON the scanner step, so the earlier steps do not cost a
    /// daemon round-trip every second.
    public func heartbeatTick() async {
        if !machine.state.isComplete, machine.state.currentStep.kind == .scanner,
           !refreshInFlight {
            refreshInFlight = true
            await machine.scanner.refresh()
            refreshInFlight = false
        }
        if !machine.state.isComplete, machine.state.currentStep.kind == .notifications,
           !refreshInFlight {
            refreshInFlight = true
            await machine.notificationsPermission.refresh()
            refreshInFlight = false
        }
        poll()
    }

    private func sync() {
        renderState = machine.state.asRenderState(now: now())
        if machine.state.isComplete && !completionDelivered {
            completionDelivered = true
            onCompleted()
        }
    }
}

/// The live onboarding surface: N10's OnboardingView bound to the controller,
/// with a 1s heartbeat driving poll() so grants landing in System Settings
/// complete their step without another click.
public struct OnboardingFlowView: View {
    @ObservedObject private var controller: OnboardingFlowController
    /// The completed walk's Done gesture. The window host passes a closure that
    /// closes the onboarding window (which also records first-run-seen).
    private let onDone: () -> Void
    private let heartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(controller: OnboardingFlowController, onDone: @escaping () -> Void = {}) {
        self.controller = controller
        self.onDone = onDone
    }

    public var body: some View {
        OnboardingView(
            state: controller.renderState,
            actions: OnboardingActions(
                primary: { Task { await controller.primaryActionAsync() } },
                skip: { controller.skip() },
                tryAgain: { Task { await controller.primaryActionAsync() } },
                openSettings: { controller.openSettings() },
                continueUnavailable: { controller.acknowledgeUnavailable() },
                relaunch: { controller.relaunch() },
                runInTerminal: { controller.openInstallInTerminal() },
                done: onDone))
            .onReceive(heartbeat) { _ in
                if !controller.isComplete {
                    Task { await controller.heartbeatTick() }
                }
            }
    }
}
