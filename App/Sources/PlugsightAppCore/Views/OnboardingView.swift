// OnboardingView.swift
//
// The onboarding window (04): the journey shown end to end as four labeled steps
// with the current position, Skip visible on every step, a fixed step-card height
// so grants landing live don't reflow the layout, and honest completion copy. The
// deeper flow is N11; this renders the surface and its states.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The button wiring for the live walk (N11). Snapshot rendering passes `.inert`
/// (the default) so the static gallery keeps rendering states without a machine.
public struct OnboardingActions {
    public let primary: () -> Void
    public let skip: () -> Void
    public let tryAgain: () -> Void
    /// Opens the current step's System Settings pane (1b/1c recovery).
    public let openSettings: () -> Void
    /// Continue past a capability the build does not ship (honest, not a wall).
    public let continueUnavailable: () -> Void
    /// Relaunch the app so a grant flipped in System Settings takes effect.
    public let relaunch: () -> Void
    /// Open Terminal.app running the ClamAV install command (WP2 fallback when the
    /// one-click install is rejected or fails).
    public let runInTerminal: () -> Void
    /// The completed walk's "Done": closes the onboarding window.
    public let done: () -> Void
    public init(primary: @escaping () -> Void = {},
                skip: @escaping () -> Void = {},
                tryAgain: @escaping () -> Void = {},
                openSettings: @escaping () -> Void = {},
                continueUnavailable: @escaping () -> Void = {},
                relaunch: @escaping () -> Void = {},
                runInTerminal: @escaping () -> Void = {},
                done: @escaping () -> Void = {}) {
        self.primary = primary; self.skip = skip; self.tryAgain = tryAgain
        self.openSettings = openSettings
        self.continueUnavailable = continueUnavailable
        self.relaunch = relaunch
        self.runInTerminal = runInTerminal
        self.done = done
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
                    .frame(height: 320)  // fixed height: live grants never reflow
            }
            if let completion = state.completionCopy {
                Text(completion).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // Persistent trust reassurance, present on every step (WP2).
            Label(TrustCopy.stayOnMac, systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
            // OS permission name, secondary under the purpose-led headline (WP2).
            if let osName = step.osName {
                Text(osName).font(.caption).foregroundStyle(.secondary)
            }
            Text(step.body).font(.callout).foregroundStyle(.secondary)
            if let warning = step.locationWarning {
                Label(warning, systemImage: "folder.badge.questionmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            grantView(step)
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

    @ViewBuilder private func grantView(_ step: OnboardingStepVM) -> some View {
        switch step.grant {
        case .notApplicable:
            EmptyView()
        case .granted:
            // "Granted" for permissions; the scanner install lands as "Installed".
            Label(step.step.landedLabel, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .notGranted(let consequence), .denied(let consequence):
            VStack(alignment: .leading, spacing: PS.s2) {
                Label(consequence, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.caption)
                if let link = state.currentStepSettingsLink {
                    Button(link.label, action: actions.openSettings).controlSize(.small).font(.caption)
                }
            }
        case .waiting(let elapsedSeconds):
            HStack(spacing: PS.s2) {
                ProgressView().controlSize(.small)
                // Elapsed seconds tick with the heartbeat: visible proof the
                // wait is live, never a frozen spinner.
                Text("Waiting for System Settings… \(elapsedSeconds)s")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                if let link = state.currentStepSettingsLink {
                    Button(link.label, action: actions.openSettings).controlSize(.small).font(.caption)
                }
                Button("Try again", action: actions.tryAgain).controlSize(.small).font(.caption)
            }
        case .needsAttention(let headline, let steps, let terminalCommand, let showRelaunch):
            VStack(alignment: .leading, spacing: PS.s2) {
                Label(headline, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption.weight(.semibold))
                Text(steps).font(.caption).foregroundStyle(.secondary)
                if let command = terminalCommand {
                    HStack(spacing: PS.s2) {
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .padding(PS.s1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                            .textSelection(.enabled)
                        Button("Copy") {
                            #if canImport(AppKit)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            #endif
                        }
                        .controlSize(.small).font(.caption)
                        // Terminal fallback: opens Terminal.app running the command
                        // so the user sees it run (WP2), never a silent shell-out.
                        Button("Install in Terminal", action: actions.runInTerminal)
                            .controlSize(.small).font(.caption)
                    }
                }
                HStack(spacing: PS.s2) {
                    if let link = state.currentStepSettingsLink {
                        Button(link.label, action: actions.openSettings).controlSize(.small).font(.caption)
                    }
                    Button("Try again", action: actions.tryAgain).controlSize(.small).font(.caption)
                    if showRelaunch {
                        Button("Relaunch Plugsight", action: actions.relaunch).controlSize(.small).font(.caption)
                    }
                }
            }
        case .unavailable(let reason):
            Label(reason, systemImage: "info.circle").foregroundStyle(.secondary).font(.caption)
        case .installing(let detail):
            // Live install: spinner + the daemon's latest progress line. Skip
            // stays in the card footer, so this is never a dead-end spinner.
            HStack(spacing: PS.s2) {
                ProgressView().controlSize(.small)
                Text(detail?.isEmpty == false ? detail! : "Installing ClamAV…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Renders the pure decision in `OnboardingState.primaryAction(for:)` (which
    /// the unit tests assert): the wording and wiring per case live here, the
    /// which-button logic lives there. A complete walk renders Done, so the last
    /// step never dead-ends on "Try again" after a successful install.
    @ViewBuilder private func primaryButton(for step: OnboardingStepVM) -> some View {
        switch state.primaryAction(for: step) {
        case .getStarted:
            Button("Get started", action: actions.primary).buttonStyle(.borderedProminent)
        case .grant:
            Button("Grant", action: actions.primary).buttonStyle(.borderedProminent)
        case .activate:
            Button("Activate", action: actions.primary).buttonStyle(.borderedProminent)
        case .continueUnavailable:
            Button("Continue", action: actions.continueUnavailable).buttonStyle(.borderedProminent)
        case .installScanner:
            Button("Install ClamAV", action: actions.primary).buttonStyle(.borderedProminent)
        case .tryAgain:
            Button("Try again", action: actions.primary).buttonStyle(.borderedProminent)
        case .done:
            Button("Done", action: actions.done).buttonStyle(.borderedProminent)
        case .none:
            EmptyView()
        }
    }
}
