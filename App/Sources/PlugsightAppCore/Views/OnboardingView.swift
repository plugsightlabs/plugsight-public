// OnboardingView.swift
//
// The onboarding window (04): the journey shown end to end as four labeled steps
// with the current position, Skip visible on every step, a fixed step-card height
// so grants landing live don't reflow the layout, and honest completion copy. The
// deeper flow is N11; this renders the surface and its states.

import SwiftUI

/// The button wiring for the live walk (N11). Snapshot rendering passes `.inert`
/// (the default) so the static gallery keeps rendering states without a machine.
public struct OnboardingActions {
    public let primary: () -> Void
    public let skip: () -> Void
    public let tryAgain: () -> Void
    public init(primary: @escaping () -> Void = {},
                skip: @escaping () -> Void = {},
                tryAgain: @escaping () -> Void = {}) {
        self.primary = primary; self.skip = skip; self.tryAgain = tryAgain
    }
    public static let inert = OnboardingActions()
}

public struct OnboardingView: View {
    let state: OnboardingState
    let actions: OnboardingActions
    public init(state: OnboardingState, actions: OnboardingActions = .inert) {
        self.state = state
        self.actions = actions
    }

    private var current: OnboardingStepVM? {
        guard state.steps.indices.contains(state.currentIndex) else { return state.steps.first }
        return state.steps[state.currentIndex]
    }

    public var body: some View {
        VStack(spacing: PS.s4) {
            stepIndicator
            if let step = current {
                stepCard(step)
                    .frame(height: 260)  // fixed height: live grants never reflow
            }
            if let completion = state.completionCopy {
                Text(completion).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(PS.s6)
        .frame(width: 520)
    }

    private var stepIndicator: some View {
        HStack(spacing: PS.s2) {
            ForEach(Array(state.steps.enumerated()), id: \.offset) { idx, step in
                HStack(spacing: PS.s1) {
                    Circle()
                        .fill(idx == state.currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(step.step.title).font(.caption2)
                        .foregroundStyle(idx == state.currentIndex ? .primary : .secondary)
                }
                if idx < state.steps.count - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 16, height: 1)
                }
            }
        }
    }

    private func stepCard(_ step: OnboardingStepVM) -> some View {
        VStack(alignment: .leading, spacing: PS.s3) {
            Text(step.headline).font(.title2.weight(.semibold))
            Text(step.body).font(.callout).foregroundStyle(.secondary)
            if let warning = step.locationWarning {
                Label(warning, systemImage: "folder.badge.questionmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            grantView(step.grant)
            Spacer()
            HStack {
                if step.showsSkip {
                    Button("Skip", action: actions.skip).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                primaryButton(for: step)
            }
        }
        .padding(PS.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func grantView(_ grant: GrantStatus) -> some View {
        switch grant {
        case .notApplicable:
            EmptyView()
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .notGranted(let consequence):
            Label(consequence, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.caption)
        case .waiting:
            HStack(spacing: PS.s2) {
                ProgressView().controlSize(.small)
                Text("Waiting for System Settings…").font(.caption).foregroundStyle(.secondary)
                Button("Try again", action: actions.tryAgain).controlSize(.small).font(.caption)
            }
        }
    }

    @ViewBuilder private func primaryButton(for step: OnboardingStepVM) -> some View {
        switch step.step {
        case .welcome:
            Button("Get started", action: actions.primary).buttonStyle(.borderedProminent)
        case .systemExtension:
            Button("Activate", action: actions.primary).buttonStyle(.borderedProminent)
        default:
            Button("Grant", action: actions.primary).buttonStyle(.borderedProminent)
        }
    }
}
