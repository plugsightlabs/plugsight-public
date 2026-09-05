// OnboardingStateMachine.swift
//
// N11: the PURE step state machine behind the onboarding window (04 "Onboarding
// window" + stories 1a-1e). It owns the four-step walk — Welcome, Input
// Monitoring, System Extension, Scanner — and the honest resulting mode. Every
// side effect it needs (probing and REQUESTING the TCC grant, driving the
// system-extension request, asking the daemon whether a scanner exists,
// registering the login item, checking the app's location) is reached through a
// protocol, so the whole machine is deterministic under fakes and CI-testable
// without TCC, SMAppService, the ES extension, or being in /Applications. The
// REAL macOS drivers (MacPermissionDrivers.swift) are thin and unit-untestable
// by design; the logic that drives them lives HERE.
//
// Canon obeyed: Skip is available on every step and never punished; a denial is
// never a wall; the location check (1d) fires BEFORE activation is attempted;
// NOTHING spins forever — every waiting state carries a start time and
// escalates to needsAttention guidance (with a real retry) once `waitTimeout`
// elapses; the extension step is honest when the build ships no extension; and
// completion states the resulting mode honestly, degraded included.

import Foundation

// MARK: - Vocabulary

public enum OnboardingStepKind: String, CaseIterable, Equatable, Sendable {
    /// Declaration order IS walk order: notifications (the core promise) comes
    /// before the scanner step.
    case welcome, inputMonitoring, systemExtension, notifications, scanner

    /// The user-recognizable name (04: internal names never reach a screen).
    public var displayName: String {
        switch self {
        case .welcome: return "Welcome"
        case .inputMonitoring: return "Input Monitoring"
        case .systemExtension: return "the system extension"
        case .notifications: return "notifications"
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

/// The state of one step. `waitingForSystemSettings` carries its start time so
/// the machine can escalate; `needsAttention` carries actionable guidance;
/// `unavailableInThisBuild` is the honest state for a capability the build does
/// not ship; `denied` carries the honest degraded consequence and (when one
/// exists) the deep link that re-opens the relevant System Settings pane.
public enum StepStatus: Equatable, Sendable {
    case pending
    case waitingForSystemSettings(since: Date)
    case granted
    case needsAttention(OnboardingStateMachine.Guidance)
    case unavailableInThisBuild(reason: String)
    case denied(consequence: String, deepLink: SystemSettingsLink?)
    case skipped
    /// The scanner step's one-click ClamAV install is running (WP2): a live
    /// spinner + the daemon's latest `installDetail`. Carries its start time so a
    /// daemon that never picks the install up escalates to the Terminal fallback
    /// instead of spinning forever. Skip stays available throughout.
    case installingScanner(since: Date, detail: String?)
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

/// TCC state for Input Monitoring: probe without prompting, and REQUEST the
/// grant (which triggers the OS prompt and lists the app in System Settings).
public protocol PermissionProbing: Sendable {
    func inputMonitoringGranted() -> Bool
    /// Drive the OS grant request (CGRequestListenEventAccess). Returns true
    /// when the grant is already in place / landed synchronously.
    @discardableResult
    func requestInputMonitoringAccess() -> Bool
}

/// Drives an OSSystemExtensionRequest. `bundledExtensionPresent` gates the whole
/// step: activation may only be offered when the build actually ships the
/// .systemextension. `requestActivation` kicks off the approval flow (which
/// lands in System Settings); `extensionActive` is polled afterwards, and
/// `lastActivationError` surfaces a delegate failure instead of dropping it.
public protocol ExtensionActivating: Sendable {
    func bundledExtensionPresent() -> Bool
    func requestActivation()
    func extensionActive() -> Bool
    func lastActivationError() -> String?
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

/// Opens a System Settings deep link (the `x-apple.systempreferences:` URLs the
/// machine already carries per step). The real impl hands the URL to NSWorkspace;
/// the fake records it, so "the grant button actually opens the pane" is testable
/// without a live login session (1b/1c/1e recovery).
public protocol SystemSettingsOpening: Sendable {
    func open(_ url: String)
}

/// Scanner availability as the DAEMON reports it (get_status scanner.available,
/// i.e. ClamAV discovery) — the real signal behind the Scanner step, replacing
/// the old Full Disk Access heuristic. `scannerAvailable` answers from the last
/// refreshed value synchronously; `refresh` re-asks the daemon.
///
/// WP2: the same status poll also carries the one-click install progress
/// (installState/installDetail), so the scanner step can show a live installing
/// state and land on done without a second round-trip. The progress accessors
/// default to idle/nil so pre-WP2 fakes keep compiling unchanged.
public protocol ScannerAvailabilityChecking: Sendable {
    func scannerAvailable() -> Bool
    func refresh() async
    /// The daemon's one-click install progress from the last `refresh()`.
    func scannerInstallState() -> StatusDTO.Scanner.InstallState
    /// The latest install progress/error line from the last `refresh()`.
    func scannerInstallDetail() -> String?
}

public extension ScannerAvailabilityChecking {
    func scannerInstallState() -> StatusDTO.Scanner.InstallState { .idle }
    func scannerInstallDetail() -> String? { nil }
}

/// The one-click ClamAV install ACTION (the scanner step's "Install ClamAV"),
/// mirroring `ScannerAvailabilityChecking`: the real impl calls the daemon's
/// `scanner.install` RPC via the APIClient; the fake scripts the result. Progress
/// after acceptance is polled through `ScannerAvailabilityChecking`, not here.
public protocol ScannerInstalling: Sendable {
    func install() async -> ScannerInstallResult
}

/// Opens Terminal.app running a shell command so the user SEES the install run
/// (the honest fallback when one-click install is rejected or fails). The app
/// never shells out silently; the point is a visible Terminal. Real impl uses
/// NSWorkspace/osascript; the fake records the command for tests.
public protocol TerminalOpening: Sendable {
    func runInTerminal(_ command: String)
}

/// Relaunches the app so a TCC grant flipped in System Settings takes effect
/// (Input Monitoring grants apply on relaunch). Real impl in
/// MacPermissionDrivers; the flow controller wires it to the guidance UI.
public protocol AppRelaunching: Sendable {
    func relaunch()
}

/// Notification permission for the onboarding notifications step, mirroring the
/// scanner driver's shape: `authorization()` answers synchronously from the
/// last `refresh()`, and `request()` drives the OS prompt (the same explicit
/// .alert + .sound ask NotificationManager.requestAuthorizationIfNeeded makes).
/// The real impl wraps the shared NotificationCenterClient; fakes script it.
public protocol NotificationPermissionChecking: Sendable {
    func authorization() -> NotificationAuthorization
    func refresh() async
    /// Ask the OS (prompts only while undetermined; a denial is respected).
    func request() async
}

/// The do-nothing default so machines built without the notifications driver
/// (older call sites, previews) keep compiling; the step then reads
/// undetermined and stays skippable.
public final class NoopNotificationPermissionChecking: NotificationPermissionChecking {
    public init() {}
    public func authorization() -> NotificationAuthorization { .notDetermined }
    public func refresh() async {}
    public func request() async {}
}

/// The REAL notification permission driver: the shared center client behind a
/// cached, lock-guarded answer the pure machine reads synchronously.
public final class CenterNotificationPermissionChecking: NotificationPermissionChecking, @unchecked Sendable {
    private let center: NotificationCenterClient
    private let lock = NSLock()
    private var lastKnown: NotificationAuthorization = .notDetermined

    public init(center: NotificationCenterClient) { self.center = center }

    public func authorization() -> NotificationAuthorization {
        lock.lock(); defer { lock.unlock() }
        return lastKnown
    }

    public func refresh() async {
        store(await center.authorizationStatus())
    }

    public func request() async {
        if await center.authorizationStatus() == .notDetermined {
            _ = await center.requestAuthorization()
        }
        store(await center.authorizationStatus())
    }

    private func store(_ auth: NotificationAuthorization) {
        lock.lock(); defer { lock.unlock() }
        lastKnown = auth
    }
}

// MARK: - The pure state machine

public final class OnboardingStateMachine {
    public private(set) var state: OnboardingMachineState

    /// Set when login-item registration fails: the walk still advances, but the
    /// failure is surfaced instead of swallowed (monitoring can still be started
    /// from the menu).
    public private(set) var loginItemWarning: String?

    /// Actionable escalation copy for a step that needs the user's attention:
    /// what happened, what to do, and the real recovery affordances.
    public struct Guidance: Equatable, Sendable {
        public let headline: String
        public let steps: String
        public let deepLink: SystemSettingsLink?
        public let terminalCommand: String?
        public let offerRelaunch: Bool
        public init(headline: String, steps: String, deepLink: SystemSettingsLink?,
                    terminalCommand: String?, offerRelaunch: Bool) {
            self.headline = headline; self.steps = steps; self.deepLink = deepLink
            self.terminalCommand = terminalCommand; self.offerRelaunch = offerRelaunch
        }
    }

    private let probe: PermissionProbing
    private let activator: ExtensionActivating
    private let loginItem: LoginItemRegistering
    private let location: AppLocationChecking
    /// Internal (not private): the flow controller's heartbeat drives
    /// `scanner.refresh()` before each poll, because the daemon-backed driver
    /// only learns anything in refresh() and poll() reads it synchronously.
    let scanner: ScannerAvailabilityChecking
    /// Internal for the same reason as `scanner`: the controller refreshes and
    /// requests through it while the walk sits on the notifications step.
    let notificationsPermission: NotificationPermissionChecking
    private let now: @Sendable () -> Date
    private let waitTimeout: TimeInterval

    public init(probe: PermissionProbing, activator: ExtensionActivating,
                loginItem: LoginItemRegistering, location: AppLocationChecking,
                scanner: ScannerAvailabilityChecking,
                notifications: NotificationPermissionChecking = NoopNotificationPermissionChecking(),
                now: @escaping @Sendable () -> Date = { Date() },
                waitTimeout: TimeInterval = 30) {
        self.probe = probe
        self.activator = activator
        self.loginItem = loginItem
        self.location = location
        self.scanner = scanner
        self.notificationsPermission = notifications
        self.now = now
        self.waitTimeout = waitTimeout
        self.state = OnboardingMachineState(steps: OnboardingStepKind.allCases.map {
            OnboardingStepState(kind: $0)
        })
    }

    /// Skip is available on EVERY step and never punished (04 primary-action row).
    public var skipAvailable: Bool { !state.isComplete }

    // MARK: Welcome

    /// "Get started": register the agent login item so monitoring begins, then
    /// advance into the permission walk. A registration failure is SURFACED via
    /// `loginItemWarning` but never blocks the walk (the daemon can also be
    /// started from the menu, 9a).
    public func getStarted() {
        guard state.currentStep.kind == .welcome else { return }
        do {
            try loginItem.register()
            loginItemWarning = nil
        } catch {
            loginItemWarning = "Plugsight could not register its background agent. "
                + "Monitoring can still be started from the menu."
        }
        setStatus(.welcome, .granted)
        advance()
    }

    // MARK: Grant / Activate

    /// The primary action for the current step. An already-granted permission
    /// completes immediately; otherwise the machine DRIVES the OS request and
    /// moves to "Waiting for System Settings" (with a start time so the wait can
    /// escalate). Pressing it again from `needsAttention` is the retry: it
    /// re-requests and resets the waiting clock.
    public func requestCurrentGrant() {
        switch state.currentStep.kind {
        case .welcome:
            getStarted()

        case .inputMonitoring:
            if probe.inputMonitoringGranted() { grantLanded(.inputMonitoring); return }
            // Actually ask the OS. This triggers the system prompt on first ask
            // and lists Plugsight in the Input Monitoring pane either way.
            if probe.requestInputMonitoringAccess() { grantLanded(.inputMonitoring); return }
            setStatus(.inputMonitoring, .waitingForSystemSettings(since: now()))

        case .systemExtension:
            // Honesty gate: a build without the .systemextension must not offer
            // a dead Activate (the request would only ever fail).
            guard activator.bundledExtensionPresent() else {
                setStatus(.systemExtension, .unavailableInThisBuild(
                    reason: "This build does not include the system extension yet. "
                        + "You keep standard monitoring."))
                return
            }
            // 1d: the location check fires BEFORE activation is attempted.
            guard location.isInApplicationsFolder() else {
                setLocationInstruction(.systemExtension, location.moveInstruction)
                return
            }
            clearLocationInstruction(.systemExtension)
            if activator.extensionActive() { grantLanded(.systemExtension) }
            else {
                activator.requestActivation()
                setStatus(.systemExtension, .waitingForSystemSettings(since: now()))
            }

        case .notifications:
            // The async OS prompt is driven from the controller layer (like the
            // scanner install); this pure call resolves what the last refresh
            // already knows: authorized lands, denied records the honest
            // consequence and advances (a denial is never a wall), undetermined
            // waits for the prompt's answer.
            switch notificationsPermission.authorization() {
            case .authorized: grantLanded(.notifications)
            case .denied: recordNotificationsDenied()
            case .notDetermined:
                setStatus(.notifications, .waitingForSystemSettings(since: now()))
            }

        case .scanner:
            // WP2: the scanner step is an explain-and-offer. An already-present
            // ClamAV lands immediately; otherwise the step stays on its current
            // status (the Install offer, or a rejected/failed guidance), and the
            // async install itself is driven from the controller layer via
            // markScannerInstalling / markScannerInstallRejected. This pure call
            // only LANDS a scanner that is already there ("Check again").
            if scannerReportsPresent() { grantLanded(.scanner) }
        }
    }

    /// Record the honest denied consequence on the notifications step and move
    /// on (shared by requestCurrentGrant and poll).
    private func recordNotificationsDenied() {
        guard let pair = Self.degradedConsequence(for: .notifications) else { return }
        setStatus(.notifications, .denied(consequence: pair.copy, deepLink: pair.deepLink))
        advance()
    }

    /// ClamAV is present per the daemon, either discovered or freshly installed.
    ///
    /// A `failed` OR in-progress (`installing`) install WINS over bare
    /// availability: a one-click install runs `brew install clamav` (which makes
    /// the BINARY present, available == true) BEFORE `freshclam` downloads the
    /// virus definitions, and installState stays `.installing` for that whole
    /// download. So while an install is in progress, bare availability must NOT
    /// land the step, or the walk completes as "monitoring active" over a scanner
    /// with zero definitions and a later freshclam failure is never shown. Only a
    /// real `.done` lands during/after an install attempt. An `idle` scanner the
    /// user already had working (available == true, no install attempted) still
    /// counts as present and lands.
    private func scannerReportsPresent() -> Bool {
        switch scanner.scannerInstallState() {
        case .failed, .installing:
            // Never land on availability alone: wait for a real `.done`.
            return scanner.scannerInstallState() == .done
        default:
            return scanner.scannerAvailable() || scanner.scannerInstallState() == .done
        }
    }

    // MARK: Scanner one-click install (WP2)

    /// The controller calls this once `scanner.install` returned accepted:true:
    /// enter the installing state so the step shows a live spinner + detail while
    /// the heartbeat polls progress. No-op off the scanner step.
    public func markScannerInstalling(detail: String?) {
        guard state.currentStep.kind == .scanner else { return }
        setStatus(.scanner, .installingScanner(since: now(), detail: detail))
    }

    /// The controller calls this when `scanner.install` returned accepted:false
    /// (an install already running, or Homebrew not found): show the daemon's
    /// reason plus the honest Terminal fallback, never a dead end. Skip stays.
    public func markScannerInstallRejected(reason: String?) {
        guard state.currentStep.kind == .scanner else { return }
        setStatus(.scanner, .needsAttention(Self.scannerInstallRejectedGuidance(reason: reason)))
    }

    /// Acknowledge an `unavailableInThisBuild` extension step and move on. The
    /// honest status is preserved, so the resulting mode counts the extension as
    /// not granted and the completion copy names it.
    public func acknowledgeUnavailable() {
        guard state.currentStep.kind == .systemExtension,
              case .unavailableInThisBuild = state.currentStep.status else { return }
        advance()
    }

    /// Live re-check while a step waits (04: steps live-update when the grant
    /// lands). A landed grant completes and advances — including from
    /// `needsAttention`, so a late grant still lands. A wait that exceeds
    /// `waitTimeout` escalates to guidance; an activation error surfaces as
    /// guidance carrying the real error text.
    public func poll() {
        let step = state.currentStep
        switch step.kind {
        case .welcome:
            break

        case .inputMonitoring:
            if probe.inputMonitoringGranted() { grantLanded(.inputMonitoring); return }
            if case let .waitingForSystemSettings(since) = step.status,
               now().timeIntervalSince(since) >= waitTimeout {
                setStatus(.inputMonitoring, .needsAttention(Self.inputMonitoringTimeoutGuidance()))
            }

        case .systemExtension:
            if activator.extensionActive() { grantLanded(.systemExtension); return }
            if let error = activator.lastActivationError() {
                setStatus(.systemExtension, .needsAttention(Self.extensionErrorGuidance(error: error)))
                return
            }
            if case let .waitingForSystemSettings(since) = step.status,
               now().timeIntervalSince(since) >= waitTimeout {
                setStatus(.systemExtension, .needsAttention(Self.extensionTimeoutGuidance()))
            }

        case .notifications:
            switch notificationsPermission.authorization() {
            case .authorized: grantLanded(.notifications); return
            case .denied:
                // A denial answered in the OS dialog resolves the step honestly.
                if case .denied = step.status {} else { recordNotificationsDenied() }
                return
            case .notDetermined: break
            }
            if case let .waitingForSystemSettings(since) = step.status,
               now().timeIntervalSince(since) >= waitTimeout {
                setStatus(.notifications, .needsAttention(Self.notificationsTimeoutGuidance()))
            }

        case .scanner:
            // Land the moment ClamAV is present (discovered or install done).
            if scannerReportsPresent() { grantLanded(.scanner); return }
            switch scanner.scannerInstallState() {
            case .installing:
                // Live progress: keep the original start time, refresh the detail.
                let since: Date
                if case let .installingScanner(started, _) = step.status { since = started }
                else { since = now() }
                setStatus(.scanner, .installingScanner(since: since, detail: scanner.scannerInstallDetail()))
            case .failed:
                setStatus(.scanner, .needsAttention(
                    Self.scannerInstallFailedGuidance(detail: scanner.scannerInstallDetail())))
            case .idle, .done:
                // done is handled by scannerReportsPresent above. While we believe
                // an install is running but the daemon has not reported `installing`
                // within the timeout, bail to the Terminal fallback rather than
                // spin forever (fail-safe; Skip is available throughout regardless).
                if case let .installingScanner(started, _) = step.status,
                   now().timeIntervalSince(started) >= waitTimeout {
                    setStatus(.scanner, .needsAttention(
                        Self.scannerInstallFailedGuidance(detail: scanner.scannerInstallDetail())))
                }
            }
        }
    }

    // MARK: Denial / Skip

    /// A denial (permission refused, extension approval declined) is NOT a wall:
    /// the step records the honest degraded consequence + a deep link when one
    /// exists, and the walk advances (1b/1c).
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

    // MARK: - Guidance copy (straight punctuation only; no em dashes)

    static func inputMonitoringTimeoutGuidance() -> Guidance {
        Guidance(
            headline: "Still waiting for Input Monitoring",
            steps: "Plugsight is now listed in System Settings > Privacy & Security > "
                + "Input Monitoring. Turn it on there. If it is already on, a relaunch "
                + "may be needed to apply the grant.",
            deepLink: SystemSettingsLink(
                label: "Open Input Monitoring settings",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
            terminalCommand: nil,
            offerRelaunch: true)
    }

    static func extensionErrorGuidance(error: String) -> Guidance {
        Guidance(
            headline: "The system extension could not be activated",
            steps: "macOS reported: \(error) Approve Plugsight under "
                + "System Settings > Privacy & Security, then try again.",
            deepLink: SystemSettingsLink(
                label: "Open System Settings",
                url: "x-apple.systempreferences:com.apple.preference.security?Security"),
            terminalCommand: nil,
            offerRelaunch: false)
    }

    static func extensionTimeoutGuidance() -> Guidance {
        Guidance(
            headline: "Still waiting for the system extension",
            steps: "Approve Plugsight under System Settings > Privacy & Security to "
                + "finish activation, or skip this step. You keep standard monitoring "
                + "either way.",
            deepLink: SystemSettingsLink(
                label: "Open System Settings",
                url: "x-apple.systempreferences:com.apple.preference.security?Security"),
            terminalCommand: nil,
            offerRelaunch: false)
    }

    /// The notification prompt was never answered within the timeout: point at
    /// the Notification settings pane instead of spinning forever. Skip stays.
    static func notificationsTimeoutGuidance() -> Guidance {
        Guidance(
            headline: "Still waiting for the notification permission",
            steps: "If the macOS dialog is gone, allow notifications for Plugsight in "
                + "System Settings > Notifications, or skip this step. Everything is "
                + "still recorded in Plugsight either way.",
            deepLink: SystemSettingsLink(
                label: "Open Notification settings",
                url: NotificationsSection.notificationSettingsURL),
            terminalCommand: nil,
            offerRelaunch: false)
    }

    /// One-click install could not be STARTED (accepted:false): surface the
    /// daemon's reason and offer the honest Terminal fallback. Skip stays.
    static func scannerInstallRejectedGuidance(reason: String?) -> Guidance {
        let why = (reason?.isEmpty == false) ? reason! : "The install could not be started."
        return Guidance(
            headline: "Couldn't start the install",
            steps: "\(why) You can install ClamAV yourself in Terminal, then this step "
                + "completes on its own. Or skip it and connection monitoring still runs.",
            deepLink: nil,
            terminalCommand: SettingsViewModel.scannerInstallCommand,
            offerRelaunch: false)
    }

    /// One-click install STARTED but did not finish (installState:failed or the
    /// daemon never picked it up): show the error tail and the Terminal fallback,
    /// with a retry via the primary button. Skip stays.
    static func scannerInstallFailedGuidance(detail: String?) -> Guidance {
        let tail = (detail?.isEmpty == false)
            ? "\(detail!) "
            : "The install did not finish. "
        return Guidance(
            headline: "The scanner install didn't finish",
            steps: "\(tail)You can try again, install ClamAV yourself in Terminal, or skip "
                + "this step and connection monitoring still runs.",
            deepLink: nil,
            terminalCommand: SettingsViewModel.scannerInstallCommand,
            offerRelaunch: false)
    }

    // MARK: - Degraded consequence copy + deep links (the exact 04 wording)

    public struct DegradedConsequence: Equatable, Sendable {
        public let copy: String
        public let deepLink: SystemSettingsLink?
    }

    /// The exact degraded consequence + System Settings deep link for a step, or
    /// nil for Welcome (no permission). The scanner carries NO deep link: no
    /// System Settings pane installs a scanner; the fix is the install command.
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
        case .notifications:
            return DegradedConsequence(
                copy: "You won't see a notification when a device looks unsafe; "
                    + "everything is still recorded in Plugsight.",
                deepLink: SystemSettingsLink(
                    label: "Open Notification settings",
                    url: NotificationsSection.notificationSettingsURL))
        case .scanner:
            return DegradedConsequence(
                copy: "Drives won't be scanned on mount until a scanner is installed.",
                deepLink: nil)
        }
    }

    // MARK: - Completion (honest resulting mode)

    /// The honest resulting mode from the final step statuses (04): all three
    /// permissions granted -> active; none -> device-connections-only; otherwise
    /// degraded, naming the first missing grant in walk order.
    public static func resultingMode(for steps: [OnboardingStepState]) -> ResultingMode {
        // Notifications gate what the user SEES, not what monitoring does, so
        // the monitoring outcome counts only the monitoring grants; a skipped
        // notification prompt showed its own honest consequence on the step.
        let permissions = steps.filter { $0.kind != .welcome && $0.kind != .notifications }
        let granted = permissions.filter { $0.status == .granted }

        if granted.count == permissions.count {
            return ResultingMode(
                outcome: .active,
                copy: "Monitoring is active. You'll see every device and be alerted to anything suspicious.")
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
