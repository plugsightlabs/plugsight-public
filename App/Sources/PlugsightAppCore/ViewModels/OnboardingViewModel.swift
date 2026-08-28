// OnboardingViewModel.swift
//
// The onboarding window (04): four labeled steps (Welcome, Input Monitoring,
// System Extension, Scanner), Skip visible on every step and never punished,
// live-updates when a grant lands, a fixed step-card height, and honest
// completion copy that states the resulting mode — including degraded. The
// deeper flow is N11; this view model renders the surface + its states.

import Foundation

public enum OnboardingStep: String, CaseIterable, Equatable, Sendable {
    case welcome, inputMonitoring, systemExtension, scanner

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .inputMonitoring: return "Input Monitoring"
        case .systemExtension: return "System Extension"
        case .scanner: return "Scanner"
        }
    }
}

public enum GrantStatus: Equatable, Sendable {
    case notApplicable          // Welcome
    case granted
    case notGranted(consequence: String)  // degraded consequence inline (1b/1c)
    case waiting                // "Waiting for System Settings" + Try again
}

public struct OnboardingStepVM: Equatable, Sendable {
    public let step: OnboardingStep
    public let headline: String
    public let body: String
    public let grant: GrantStatus
    /// Skip is visible on every step (04).
    public let showsSkip: Bool
    /// The location check renders inside the extension step (1d).
    public let locationWarning: String?
    public init(step: OnboardingStep, headline: String, body: String, grant: GrantStatus,
                showsSkip: Bool, locationWarning: String?) {
        self.step = step; self.headline = headline; self.body = body
        self.grant = grant; self.showsSkip = showsSkip; self.locationWarning = locationWarning
    }
}

public struct OnboardingState: Equatable, Sendable {
    public var steps: [OnboardingStepVM]
    public var currentIndex: Int
    /// Set once the walk is complete; states the resulting mode honestly.
    public var completionCopy: String?
    public init(steps: [OnboardingStepVM], currentIndex: Int, completionCopy: String?) {
        self.steps = steps; self.currentIndex = currentIndex; self.completionCopy = completionCopy
    }
}

@MainActor
public final class OnboardingViewModel: ObservableObject {
    @Published public private(set) var state: OnboardingState
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
        self.state = OnboardingState(steps: [], currentIndex: 0, completionCopy: nil)
    }
    public init(previewState: OnboardingState) {
        self.api = FakeAPIClient(); self.state = previewState
    }

    /// Build the four step cards from current status. Pure so the live-update and
    /// completion-copy honesty are testable.
    public static func steps(from status: StatusDTO) -> [OnboardingStepVM] {
        let welcome = OnboardingStepVM(
            step: .welcome,
            headline: "Plugsight shows you what your USB devices actually do.",
            body: "It watches, explains, and never pretends to block.",
            grant: .notApplicable, showsSkip: true, locationWarning: nil)

        let im = OnboardingStepVM(
            step: .inputMonitoring,
            headline: "Turn on Input Monitoring",
            body: "This lets Plugsight score typing behavior and catch keystroke-injection "
                + "attacks. Skip it and connection and mismatch monitoring still run.",
            grant: status.permissions.inputMonitoring
                ? .granted
                : .notGranted(consequence: "Typing-behavior scoring stays off; "
                    + "enumeration and mismatch detection still run."),
            showsSkip: true, locationWarning: nil)

        let extGrant: GrantStatus
        switch status.permissions.esExtension {
        case .active: extGrant = .granted
        case .inactive: extGrant = .notGranted(consequence:
            "You keep standard monitoring; higher-fidelity features and holding new drives stay off.")
        case .notInstalled: extGrant = .waiting
        }
        let ext = OnboardingStepVM(
            step: .systemExtension,
            headline: "Activate the system extension",
            body: "This adds higher-fidelity monitoring. Approve it in System Settings when asked.",
            grant: extGrant, showsSkip: true,
            // The location check (1d) renders here, before activation is attempted.
            locationWarning: nil)

        let scanner = OnboardingStepVM(
            step: .scanner,
            headline: "Set up the scanner",
            body: "With a scanner, Plugsight checks drives for known malware on mount. "
                + "Skip it and connection monitoring still runs.",
            grant: status.scanner.available
                ? .granted
                : .notGranted(consequence: "Drives won’t be scanned on mount until a scanner is installed."),
            showsSkip: true, locationWarning: nil)

        return [welcome, im, ext, scanner]
    }

    /// Honest completion copy for the resulting mode — degraded stated, not hidden.
    public static func completionCopy(for status: StatusDTO) -> String {
        switch status.monitoring {
        case .active:
            return "Monitoring is active. You’ll see every device and be alerted to anything suspicious."
        case .degraded:
            if let grant = GrantNaming.firstMissingGrant(status) {
                return "Monitoring is running, but \(grant) is off, so some checks are disabled. "
                    + "You can turn it on any time in Settings."
            }
            return "Monitoring is running in a reduced mode. You can finish setup in Settings."
        case .stopped:
            return "Monitoring device connections only. Turn on the rest any time in Settings."
        }
    }

    public func load() async {
        do {
            let status = try await api.getStatus()
            state = OnboardingState(
                steps: Self.steps(from: status),
                currentIndex: state.currentIndex,
                completionCopy: nil)
        } catch {
            // Onboarding never blocks on a read failure; show the steps as ungranted.
            state = OnboardingState(steps: Self.steps(from: Canned.statusStopped),
                                    currentIndex: 0, completionCopy: nil)
        }
    }
}
