// OnboardingStateMachine.swift
//
// N11: the PURE step state machine behind the onboarding window (04 "Onboarding
// window" + stories 1a-1e). It owns the four-step walk — Welcome, Input
// Monitoring, System Extension, Scanner — and the honest resulting mode. Every
// side effect it needs (probing TCC state, driving the system-extension
// request, registering the login item, checking the app's location) is reached
// through a protocol, so the whole machine is deterministic under fakes and
// CI-testable without TCC, SMAppService, the ES extension, or being in
// /Applications. The REAL macOS drivers (MacPermissionDrivers.swift) are thin
// and unit-untestable by design; the logic that drives them lives HERE.
//
// Canon obeyed: Skip is available on every step and never punished; a denial is
// never a wall (it advances, carrying the exact 04 consequence copy + a working
// deep link); the location check (1d) fires BEFORE activation is attempted; and
// completion states the resulting mode honestly, degraded included.

import Foundation

// MARK: - Vocabulary

public enum OnboardingStepKind: String, CaseIterable, Equatable, Sendable {
    case welcome, inputMonitoring, systemExtension, scanner

    /// The user-recognizable name (04: internal names never reach a screen).
    public var displayName: String {
        switch self {
        case .welcome: return "Welcome"
        case .inputMonitoring: return "Input Monitoring"
        case .systemExtension: return "the system extension"
        case .scanner: return "the scanner"
        }
    }
}

/// A deep link into System Settings for a specific privacy pane (1b/1c).
public struct SystemSettingsLink: Equatable, Sendable {
    public let label: String
    public let url: String
    public init(label: String, url: String) { self.label = label; self.url = url }
}

/// The state of one step. `denied` carries the honest degraded consequence and
/// the deep link that re-opens the relevant System Settings pane.
public enum StepStatus: Equatable, Sendable {
    case pending
    case waitingForSystemSettings
    case granted
    case denied(consequence: String, deepLink: SystemSettingsLink)
    case skipped
}

public struct OnboardingStepState: Equatable, Sendable {
    public let kind: OnboardingStepKind
    public var status: StepStatus
    /// Only the extension step carries this: the /Applications move instruction
    /// (1d), set BEFORE activation is attempted when the app is mislocated.
    public var locationInstruction: String?
    public init(kind: OnboardingStepKind, status: StepStatus = .pending,
                locationInstruction: String? = nil) {
        self.kind = kind; self.status = status; self.locationInstruction = locationInstruction
    }
}

public enum MonitoringOutcome: Equatable, Sendable {
    case active          // every permission granted
    case degraded        // some granted, some not
    case connectionsOnly // nothing granted — device-connection monitoring only
}

/// The honest resulting mode shown at completion (04: degraded stated, not hidden).
public struct ResultingMode: Equatable, Sendable {
    public let outcome: MonitoringOutcome
    public let copy: String
    public init(outcome: MonitoringOutcome, copy: String) {
        self.outcome = outcome; self.copy = copy
    }
}

public struct OnboardingMachineState: Equatable, Sendable {
    public var steps: [OnboardingStepState]
    public var currentIndex: Int
    /// Set once the walk finishes; nil while in progress.
    public var resultingMode: ResultingMode?

    public init(steps: [OnboardingStepState], currentIndex: Int = 0,
                resultingMode: ResultingMode? = nil) {
        self.steps = steps; self.currentIndex = currentIndex; self.resultingMode = resultingMode
    }

    public var currentStep: OnboardingStepState { steps[currentIndex] }
    public var isComplete: Bool { resultingMode != nil }

    /// The step of a given kind (the four kinds are unique).
    public func step(_ kind: OnboardingStepKind) -> OnboardingStepState {
        steps.first { $0.kind == kind }!
    }
}

// MARK: - Driver protocols (real impls in MacPermissionDrivers.swift; fakes in Testing/)

/// TCC state polling for Input Monitoring / Full Disk Access (04 "poll TCC state").
public protocol PermissionProbing: Sendable {
    func inputMonitoringGranted() -> Bool
    func fullDiskAccessGranted() -> Bool
}

/// Drives an OSSystemExtensionRequest. `requestActivation` kicks off the
/// approval flow (which lands in System Settings); `extensionActive` is polled
/// afterwards to see whether the user approved it.
public protocol ExtensionActivating: Sendable {
    func requestActivation()
    func extensionActive() -> Bool
}

/// Registers the background agent as an SMAppService login item so monitoring
/// persists across logins.
public protocol LoginItemRegistering: Sendable {
    func register() throws
    func isRegistered() -> Bool
}

/// Is the app running from /Applications (1d). When false the extension step
/// shows the move instruction instead of attempting activation.
public protocol AppLocationChecking: Sendable {
    func isInApplicationsFolder() -> Bool
    var moveInstruction: String { get }
}

// MARK: - The pure state machine

public final class OnboardingStateMachine {
    public private(set) var state: OnboardingMachineState

    private let probe: PermissionProbing
    private let activator: ExtensionActivating
    private let loginItem: LoginItemRegistering
    private let location: AppLocationChecking

    public init(probe: PermissionProbing, activator: ExtensionActivating,
                loginItem: LoginItemRegistering, location: AppLocationChecking) {
        self.probe = probe
        self.activator = activator
        self.loginItem = loginItem
        self.location = location
        self.state = OnboardingMachineState(steps: OnboardingStepKind.allCases.map {
            OnboardingStepState(kind: $0)
        })
    }

    /// Skip is available on EVERY step and never punished (04 primary-action row).
    public var skipAvailable: Bool { !state.isComplete }

    // MARK: Welcome

    /// "Get started": register the agent login item so monitoring begins, then
    /// advance into the permission walk. Registration failure is swallowed — the
    /// walk never blocks on it (the daemon can also be started from the menu, 9a).
    public func getStarted() {
        guard state.currentStep.kind == .welcome else { return }
        try? loginItem.register()
        setStatus(.welcome, .granted)
        advance()
    }

    // MARK: Grant / Activate

    /// The primary action for the current step. Probes/drives the right layer:
    /// an already-granted permission completes immediately; otherwise the step
    /// moves to "Waiting for System Settings" and is completed later by `poll()`.
    public func requestCurrentGrant() {
        switch state.currentStep.kind {
        case .welcome:
            getStarted()

        case .inputMonitoring:
            if probe.inputMonitoringGranted() { grantLanded(.inputMonitoring) }
            else { setStatus(.inputMonitoring, .waitingForSystemSettings) }

        case .systemExtension:
            // 1d: the location check fires BEFORE activation is attempted.
            guard location.isInApplicationsFolder() else {
                setLocationInstruction(.systemExtension, location.moveInstruction)
                return
            }
            clearLocationInstruction(.systemExtension)
            if activator.extensionActive() { grantLanded(.systemExtension) }
            else {
                activator.requestActivation()
                setStatus(.systemExtension, .waitingForSystemSettings)
            }

        case .scanner:
            if probe.fullDiskAccessGranted() { grantLanded(.scanner) }
            else { setStatus(.scanner, .waitingForSystemSettings) }
        }
    }

    /// Live re-check while a step waits for System Settings (04: steps
    /// live-update when the grant lands). A landed grant completes and advances.
    public func poll() {
        let kind = state.currentStep.kind
        switch kind {
        case .inputMonitoring where probe.inputMonitoringGranted():
            grantLanded(kind)
        case .systemExtension where activator.extensionActive():
            grantLanded(kind)
        case .scanner where probe.fullDiskAccessGranted():
            grantLanded(kind)
        default:
            break
        }
    }

    // MARK: Denial / Skip

    /// A denial (permission refused, extension approval declined) is NOT a wall:
    /// the step records the honest degraded consequence + a deep link, and the
    /// walk advances (1b/1c).
    public func denyCurrent() {
        let kind = state.currentStep.kind
        guard let pair = Self.degradedConsequence(for: kind) else { return }
        setStatus(kind, .denied(consequence: pair.copy, deepLink: pair.deepLink))
        advance()
    }

    /// Skip the current step. Always available, never punished — it records a
    /// neutral `.skipped`, never a denied/degraded state.
    public func skipCurrent() {
        setStatus(state.currentStep.kind, .skipped)
        advance()
    }

    // MARK: - Degraded consequence copy + deep links (the exact 04 wording)

    public struct DegradedConsequence: Equatable, Sendable {
        public let copy: String
        public let deepLink: SystemSettingsLink
    }

    /// The exact degraded consequence + System Settings deep link for a step, or
    /// nil for Welcome (no permission). Copy names user-recognizable things only.
    public static func degradedConsequence(for kind: OnboardingStepKind) -> DegradedConsequence? {
        switch kind {
        case .welcome:
            return nil
        case .inputMonitoring:
            return DegradedConsequence(
                copy: "Typing-behavior scoring stays off; enumeration and mismatch detection still run.",
                deepLink: SystemSettingsLink(
                    label: "Open Input Monitoring settings",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"))
        case .systemExtension:
            return DegradedConsequence(
                copy: "You keep standard monitoring; higher-fidelity features and holding new drives stay off.",
                deepLink: SystemSettingsLink(
                    label: "Open System Settings",
                    url: "x-apple.systempreferences:com.apple.preference.security?Security"))
        case .scanner:
            return DegradedConsequence(
                copy: "Drives won’t be scanned on mount until a scanner is installed.",
                deepLink: SystemSettingsLink(
                    label: "Open Full Disk Access settings",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"))
        }
    }

    // MARK: - Completion (honest resulting mode)

    /// The honest resulting mode from the final step statuses (04): all three
    /// permissions granted -> active; none -> device-connections-only; otherwise
    /// degraded, naming the first missing grant in walk order.
    public static func resultingMode(for steps: [OnboardingStepState]) -> ResultingMode {
        let permissions = steps.filter { $0.kind != .welcome }
        let granted = permissions.filter { $0.status == .granted }

        if granted.count == permissions.count {
            return ResultingMode(
                outcome: .active,
                copy: "Monitoring is active. You’ll see every device and be alerted to anything suspicious.")
        }
        if granted.isEmpty {
            return ResultingMode(
                outcome: .connectionsOnly,
                copy: "Monitoring device connections only. Turn on the rest any time in Settings.")
        }
        let missing = permissions.first { $0.status != .granted }!
        return ResultingMode(
            outcome: .degraded,
            copy: "Monitoring is running, but \(missing.kind.displayName) is off, so some checks are disabled. "
                + "You can turn it on any time in Settings.")
    }

    // MARK: - Private mutation helpers

    private func advance() {
        if state.currentIndex + 1 < state.steps.count {
            state.currentIndex += 1
        } else {
            state.resultingMode = Self.resultingMode(for: state.steps)
        }
    }

    private func grantLanded(_ kind: OnboardingStepKind) {
        setStatus(kind, .granted)
        advance()
    }

    private func setStatus(_ kind: OnboardingStepKind, _ status: StepStatus) {
        guard let i = state.steps.firstIndex(where: { $0.kind == kind }) else { return }
        state.steps[i].status = status
    }

    private func setLocationInstruction(_ kind: OnboardingStepKind, _ instruction: String) {
        guard let i = state.steps.firstIndex(where: { $0.kind == kind }) else { return }
        state.steps[i].locationInstruction = instruction
    }

    private func clearLocationInstruction(_ kind: OnboardingStepKind) {
        guard let i = state.steps.firstIndex(where: { $0.kind == kind }) else { return }
        state.steps[i].locationInstruction = nil
    }
}
