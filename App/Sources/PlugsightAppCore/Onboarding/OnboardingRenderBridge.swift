// OnboardingRenderBridge.swift
//
// N11 reuses N10's onboarding VIEW rather than duplicating it. N10 built
// `OnboardingView(state: OnboardingState)` and the `OnboardingStepVM`/`GrantStatus`
// surface vocabulary; N11 owns the real step state machine. This bridge maps the
// machine's state onto N10's `OnboardingState` so the SAME SwiftUI view renders
// the live walk — no second onboarding view exists.

import Foundation

extension OnboardingMachineState {

    /// Project the machine state onto N10's render surface so `OnboardingView`
    /// renders it unchanged. Headline/body copy comes from N10's canonical step
    /// text; grant status and the location warning come from the machine. `now`
    /// is injected so the waiting step's elapsed seconds are deterministic.
    public func asRenderState(now: Date = Date()) -> OnboardingState {
        let vms = steps.map { step -> OnboardingStepVM in
            let n10 = step.kind.n10Step
            return OnboardingStepVM(
                step: n10,
                headline: n10.headline,   // single source (OnboardingStep) - GAP-7
                body: n10.body,
                grant: Self.grantStatus(for: step, now: now),
                // Skip is on every step of the WALK; once the walk is complete
                // there is nothing left to skip and the primary becomes Done.
                showsSkip: resultingMode == nil,
                locationWarning: step.locationInstruction,
                osName: n10.osNameSecondary)
        }
        // Surface the current step's System Settings deep link (nil for Welcome,
        // for the scanner step, whose recovery is Terminal, and once the walk is
        // complete) so the view can offer a real "Open settings" recovery
        // instead of dropping it (1b/1c/1e).
        let link = resultingMode == nil
            ? OnboardingStateMachine.degradedConsequence(for: steps[currentIndex].kind)?.deepLink
            : nil
        return OnboardingState(steps: vms, currentIndex: currentIndex,
                               completionCopy: resultingMode?.copy,
                               currentStepSettingsLink: link)
    }

    private static func grantStatus(for step: OnboardingStepState, now: Date) -> GrantStatus {
        if step.kind == .welcome { return .notApplicable }
        switch step.status {
        case .granted:
            return .granted
        case .waitingForSystemSettings(let since):
            return .waiting(elapsedSeconds: max(0, Int(now.timeIntervalSince(since))))
        case .needsAttention(let guidance):
            return .needsAttention(headline: guidance.headline, steps: guidance.steps,
                                   terminalCommand: guidance.terminalCommand,
                                   showRelaunch: guidance.offerRelaunch)
        case .unavailableInThisBuild(let reason):
            return .unavailable(reason: reason)
        case .installingScanner(_, let detail):
            return .installing(detail: detail)
        case .denied(let consequence, _):
            // Denied stays denied: it must not collapse into the pre-grant look.
            return .denied(consequence: consequence)
        case .pending:
            // BEFORE any choice there is no warning: the card body explains the
            // step, and the "stays off" consequence waits for Skip/deny.
            return .undecided
        case .skipped:
            // Skipped shows what stays off — the honest consequence — as N10's
            // inline degraded copy.
            let consequence = OnboardingStateMachine.degradedConsequence(for: step.kind)?.copy ?? ""
            return .notGranted(consequence: consequence)
        }
    }
}

private extension OnboardingStepKind {
    /// Map to N10's step enum (same four cases, same order). Headline/body copy
    /// lives on OnboardingStep, the single source (GAP-7).
    var n10Step: OnboardingStep {
        switch self {
        case .welcome: return .welcome
        case .inputMonitoring: return .inputMonitoring
        case .systemExtension: return .systemExtension
        case .notifications: return .notifications
        case .scanner: return .scanner
        }
    }
}
