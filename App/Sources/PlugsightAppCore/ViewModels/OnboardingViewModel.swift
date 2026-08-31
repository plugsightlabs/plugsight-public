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

    /// The step-indicator chip label: purpose-led and short (WP2). The full
    /// purpose sentence is the card `headline`; the OS name is `osNameSecondary`.
    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .inputMonitoring: return "Typing rhythm"
        case .systemExtension: return "Deeper monitoring"
        case .scanner: return "Malware scan"
        }
    }

    /// The canonical step headline. Single source for both the live walk (via the
    /// render bridge) and the status-built preview (steps(from:)) - GAP-7 dedup.
    /// Purpose leads (WP2); the OS permission name is the secondary line below.
    public var headline: String {
        switch self {
        case .welcome: return "Plugsight shows you what your USB devices actually do."
        case .inputMonitoring: return "Check typing rhythm, not your keystrokes"
        case .systemExtension: return "Turn on deeper device monitoring"
        case .scanner: return ScannerCopy.explanationHeadline
        }
    }

    /// The OS permission / engine name, shown as a secondary line under the
    /// purpose-led headline so users can still match it in System Settings (WP2).
    public var osNameSecondary: String? {
        switch self {
        case .welcome: return nil
        case .inputMonitoring: return "macOS permission: \(PermissionVocabulary.inputMonitoring.osName)"
        case .systemExtension: return "macOS permission: \(PermissionVocabulary.systemExtension.osName)"
        case .scanner: return "Uses ClamAV, a free open-source scanner"
        }
    }

    /// The green landed-state label. Permission steps land as "Granted"; the
    /// scanner step is a software install, so "Granted" would be the wrong
    /// vocabulary and it lands as "Installed".
    public var landedLabel: String {
        self == .scanner ? "Installed" : "Granted"
    }

    /// The canonical step body (see `headline`).
    public var body: String {
        switch self {
        case .welcome:
            return "It watches, explains, and never pretends to block."
        case .inputMonitoring:
            return InputMonitoringCopy.reframedBody
        case .systemExtension:
            return "This adds higher-fidelity monitoring on your Mac. Approve it in "
                + "System Settings when asked. It is optional."
        case .scanner:
            return ScannerCopy.explanationBody
        }
    }
}

public enum GrantStatus: Equatable, Sendable {
    case notApplicable          // Welcome
    case granted
    case notGranted(consequence: String)  // pre-grant/skipped: degraded consequence inline (1b/1c)
    case denied(consequence: String)      // explicitly refused: distinct from notGranted
    case waiting(elapsedSeconds: Int)     // "Waiting for System Settings" + Try again
    /// The wait escalated (timeout, activation error, missing scanner): honest
    /// guidance with a real recovery, never an endless spinner.
    case needsAttention(headline: String, steps: String, terminalCommand: String?, showRelaunch: Bool)
    /// The build does not ship this capability; Continue instead of a dead grant.
    case unavailable(reason: String)
    /// The scanner's one-click ClamAV install is running (WP2): a live spinner and
    /// the daemon's latest progress line. Skip stays available.
    case installing(detail: String?)
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
    /// The OS permission / engine name, secondary under the purpose-led headline (WP2).
    public let osName: String?
    public init(step: OnboardingStep, headline: String, body: String, grant: GrantStatus,
                showsSkip: Bool, locationWarning: String?, osName: String? = nil) {
        self.step = step; self.headline = headline; self.body = body
        self.grant = grant; self.showsSkip = showsSkip; self.locationWarning = locationWarning
        self.osName = osName
    }
}

public struct OnboardingState: Equatable, Sendable {
    public var steps: [OnboardingStepVM]
    public var currentIndex: Int
    /// Set once the walk is complete; states the resulting mode honestly.
    public var completionCopy: String?
    /// The System Settings deep link for the CURRENT step, when it has one (every
    /// permission step does; Welcome does not). The walk surfaces it as an "Open
    /// settings" button so a not-yet-granted step has a real recovery, not a
    /// spinner that waits forever (1b/1c).
    public var currentStepSettingsLink: SystemSettingsLink?
    public init(steps: [OnboardingStepVM], currentIndex: Int, completionCopy: String?,
                currentStepSettingsLink: SystemSettingsLink? = nil) {
        self.steps = steps; self.currentIndex = currentIndex; self.completionCopy = completionCopy
        self.currentStepSettingsLink = currentStepSettingsLink
    }
}

/// The primary button a step card renders. Pure render decision, unit-testable
/// without SwiftUI; `OnboardingView.primaryButton(for:)` switches on it.
public enum OnboardingPrimaryAction: Equatable, Sendable {
    case getStarted            // Welcome
    case grant                 // permission steps
    case activate              // system extension
    case continueUnavailable   // capability the build does not ship
    case installScanner        // WP2 one-click ClamAV offer
    case tryAgain              // rejected/failed scanner install
    case done                  // walk complete: close the window
    case none                  // no primary (install spinner; Skip carries the step)
}

extension OnboardingState {
    /// Which primary button to render for a step. A COMPLETE walk always renders
    /// Done: the machine keeps `currentIndex` on the last step after it lands, so
    /// without this the scanner step would dead-end on "Try again" after a
    /// successful install (the live-verified regression).
    public func primaryAction(for step: OnboardingStepVM) -> OnboardingPrimaryAction {
        if completionCopy != nil { return .done }
        switch step.step {
        case .welcome:
            return .getStarted
        case .systemExtension:
            if case .unavailable = step.grant { return .continueUnavailable }
            return .activate
        case .scanner:
            // WP2 explain-and-offer: the offer's primary is "Install ClamAV";
            // while installing there is no primary (spinner + Skip carry the
            // step); a rejection/failure retries; a landed final step is the
            // complete walk handled above.
            switch step.grant {
            case .notGranted: return .installScanner
            case .installing: return .none
            case .granted: return .done
            default: return .tryAgain
            }
        case .inputMonitoring:
            return .grant
        }
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
            headline: OnboardingStep.welcome.headline,
            body: OnboardingStep.welcome.body,
            grant: .notApplicable, showsSkip: true, locationWarning: nil,
            osName: OnboardingStep.welcome.osNameSecondary)

        let im = OnboardingStepVM(
            step: .inputMonitoring,
            headline: OnboardingStep.inputMonitoring.headline,
            body: OnboardingStep.inputMonitoring.body,
            grant: status.permissions.inputMonitoring
                ? .granted
                : .notGranted(consequence: "Typing-behavior scoring stays off; "
                    + "enumeration and mismatch detection still run."),
            showsSkip: true, locationWarning: nil,
            osName: OnboardingStep.inputMonitoring.osNameSecondary)

        let extGrant: GrantStatus
        switch status.permissions.esExtension {
        case .active: extGrant = .granted
        case .inactive: extGrant = .notGranted(consequence:
            "You keep standard monitoring; higher-fidelity features and holding new drives stay off.")
        case .notInstalled: extGrant = .waiting(elapsedSeconds: 0)
        }
        let ext = OnboardingStepVM(
            step: .systemExtension,
            headline: OnboardingStep.systemExtension.headline,
            body: OnboardingStep.systemExtension.body,
            grant: extGrant, showsSkip: true,
            // The location check (1d) renders here, before activation is attempted.
            locationWarning: nil,
            osName: OnboardingStep.systemExtension.osNameSecondary)

        let scanner = OnboardingStepVM(
            step: .scanner,
            headline: OnboardingStep.scanner.headline,
            body: OnboardingStep.scanner.body,
            grant: status.scanner.available
                ? .granted
                : .notGranted(consequence: "Drives won’t be scanned on mount until a scanner is installed."),
            showsSkip: true, locationWarning: nil,
            osName: OnboardingStep.scanner.osNameSecondary)

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
