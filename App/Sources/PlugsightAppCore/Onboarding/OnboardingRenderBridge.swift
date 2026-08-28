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
    /// text; grant status and the location warning come from the machine.
    public func asRenderState() -> OnboardingState {
        let vms = steps.map { step -> OnboardingStepVM in
            OnboardingStepVM(
                step: step.kind.n10Step,
                headline: step.kind.n10Headline,
                body: step.kind.n10Body,
                grant: Self.grantStatus(for: step),
                showsSkip: true,
                locationWarning: step.locationInstruction)
        }
        return OnboardingState(steps: vms, currentIndex: currentIndex,
                               completionCopy: resultingMode?.copy)
    }

    private static func grantStatus(for step: OnboardingStepState) -> GrantStatus {
        if step.kind == .welcome { return .notApplicable }
        switch step.status {
        case .granted:
            return .granted
        case .waitingForSystemSettings:
            return .waiting
        case .denied(let consequence, _):
            return .notGranted(consequence: consequence)
        case .pending, .skipped:
            // Pre-grant and skipped both show what stays off — the honest
            // consequence — as N10's inline degraded copy.
            let consequence = OnboardingStateMachine.degradedConsequence(for: step.kind)?.copy ?? ""
            return .notGranted(consequence: consequence)
        }
    }
}

private extension OnboardingStepKind {
    /// Map to N10's step enum (same four cases, same order).
    var n10Step: OnboardingStep {
        switch self {
        case .welcome: return .welcome
        case .inputMonitoring: return .inputMonitoring
        case .systemExtension: return .systemExtension
        case .scanner: return .scanner
        }
    }

    var n10Headline: String {
        switch self {
        case .welcome: return "Plugsight shows you what your USB devices actually do."
        case .inputMonitoring: return "Turn on Input Monitoring"
        case .systemExtension: return "Activate the system extension"
        case .scanner: return "Set up the scanner"
        }
    }

    var n10Body: String {
        switch self {
        case .welcome:
            return "It watches, explains, and never pretends to block."
        case .inputMonitoring:
            return "This lets Plugsight score typing behavior and catch keystroke-injection "
                + "attacks. Skip it and connection and mismatch monitoring still run."
        case .systemExtension:
            return "This adds higher-fidelity monitoring. Approve it in System Settings when asked."
        case .scanner:
            return "With a scanner, Plugsight checks drives for known malware on mount. "
                + "Skip it and connection monitoring still runs."
        }
    }
}
