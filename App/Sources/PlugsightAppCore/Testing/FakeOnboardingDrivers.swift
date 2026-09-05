// FakeOnboardingDrivers.swift
//
// Fakes for the onboarding driver protocols, so the pure state machine is
// exercised without TCC, SMAppService, the ES extension, the daemon, or being
// in /Applications. Each fake is a mutable class the tests toggle to simulate a
// grant landing, a denial, a missing scanner, or a mislocated app. Shipped in
// the library's Testing/ folder (like FakeAPIClient) so both the unit tests and
// previews can drive the machine deterministically.

import Foundation

public final class FakePermissionProbing: PermissionProbing, @unchecked Sendable {
    public var inputMonitoring: Bool
    /// When true, `requestInputMonitoringAccess` grants synchronously (the user
    /// hits Allow on the prompt); when false, the request is declined/pending.
    public var grantOnRequest: Bool
    /// How many times the OS request was actually driven — the tests assert the
    /// machine asks the OS instead of just re-probing forever.
    public private(set) var requestCount = 0

    public init(inputMonitoring: Bool = false, grantOnRequest: Bool = false) {
        self.inputMonitoring = inputMonitoring
        self.grantOnRequest = grantOnRequest
    }

    public func inputMonitoringGranted() -> Bool { inputMonitoring }

    @discardableResult
    public func requestInputMonitoringAccess() -> Bool {
        requestCount += 1
        if grantOnRequest { inputMonitoring = true }
        return inputMonitoring
    }
}

public final class FakeExtensionActivating: ExtensionActivating, @unchecked Sendable {
    public var active: Bool
    /// Whether the build "ships" the .systemextension. Defaults to true so the
    /// activation-path tests keep their meaning; the honesty tests set false.
    public var bundled: Bool
    /// A delegate failure to surface on the next lastActivationError() read.
    public var errorToReport: String?
    /// How many times activation was actually driven — the location-gate and
    /// no-bundle tests assert this stays 0.
    public private(set) var activationRequests = 0

    public init(active: Bool = false, bundled: Bool = true) {
        self.active = active
        self.bundled = bundled
    }

    public func bundledExtensionPresent() -> Bool { bundled }

    public func requestActivation() {
        activationRequests += 1
        errorToReport = nil   // mirrors the real driver: a new request clears the last error
    }

    public func extensionActive() -> Bool { active }

    public func lastActivationError() -> String? { errorToReport }
}

public final class FakeLoginItemRegistering: LoginItemRegistering, @unchecked Sendable {
    public private(set) var registrations = 0
    public var registered: Bool
    public var errorToThrow: Error?
    public init(registered: Bool = false) { self.registered = registered }
    public func register() throws {
        if let e = errorToThrow { throw e }
        registrations += 1
        registered = true
    }
    public func isRegistered() -> Bool { registered }
}

public final class FakeAppLocationChecking: AppLocationChecking, @unchecked Sendable {
    public var inApplications: Bool
    public var moveInstruction: String
    public init(inApplications: Bool = true,
                moveInstruction: String = "Move Plugsight to your Applications folder, then reopen it to continue.") {
        self.inApplications = inApplications
        self.moveInstruction = moveInstruction
    }
    public func isInApplicationsFolder() -> Bool { inApplications }
}

public final class FakeSystemSettingsOpener: SystemSettingsOpening, @unchecked Sendable {
    /// Every deep link the app asked to open, in order — so a test can assert the
    /// Grant / Open System Settings button opened the correct pane (1b/1c/1e).
    public private(set) var opened: [String] = []
    public init() {}
    public func open(_ url: String) { opened.append(url) }
}

public final class FakeScannerAvailability: ScannerAvailabilityChecking, @unchecked Sendable {
    public var available: Bool
    /// The one-click install progress the scanner step polls (WP2). Tests set
    /// these to simulate the daemon reporting installing / done / failed.
    public var installState: StatusDTO.Scanner.InstallState
    public var installDetail: String?
    public private(set) var refreshCalls = 0
    public init(available: Bool = false,
                installState: StatusDTO.Scanner.InstallState = .idle,
                installDetail: String? = nil) {
        self.available = available
        self.installState = installState
        self.installDetail = installDetail
    }
    public func scannerAvailable() -> Bool { available }
    public func scannerInstallState() -> StatusDTO.Scanner.InstallState { installState }
    public func scannerInstallDetail() -> String? { installDetail }
    public func refresh() async { refreshCalls += 1 }
}

/// Fake one-click installer: scripts the ScannerInstallResult and spies whether
/// install() ran (WP2 onboarding tests).
public final class FakeScannerInstalling: ScannerInstalling, @unchecked Sendable {
    public var result: ScannerInstallResult
    public private(set) var installCalls = 0
    public init(result: ScannerInstallResult = ScannerInstallResult(accepted: true, reason: nil)) {
        self.result = result
    }
    public func install() async -> ScannerInstallResult {
        installCalls += 1
        return result
    }
}

/// Fake Terminal opener: records the command it was asked to run so a test can
/// assert the fallback opens Terminal with the expected install command.
public final class FakeTerminalOpening: TerminalOpening, @unchecked Sendable {
    public private(set) var commands: [String] = []
    public init() {}
    public func runInTerminal(_ command: String) { commands.append(command) }
}

/// Fake notification permission: scripts the authorization ladder and spies
/// request()/refresh() so the notifications step is testable without the OS
/// notification center.
public final class FakeNotificationPermission: NotificationPermissionChecking, @unchecked Sendable {
    public var current: NotificationAuthorization
    /// What the OS prompt resolves to when request() runs while undetermined.
    public var answerOnRequest: NotificationAuthorization
    public private(set) var requestCalls = 0
    public private(set) var refreshCalls = 0
    public init(current: NotificationAuthorization = .notDetermined,
                answerOnRequest: NotificationAuthorization = .notDetermined) {
        self.current = current
        self.answerOnRequest = answerOnRequest
    }
    public func authorization() -> NotificationAuthorization { current }
    public func refresh() async { refreshCalls += 1 }
    public func request() async {
        requestCalls += 1
        if current == .notDetermined { current = answerOnRequest }
    }
}

public final class FakeAppRelaunching: AppRelaunching, @unchecked Sendable {
    public private(set) var relaunchCalls = 0
    public init() {}
    public func relaunch() { relaunchCalls += 1 }
}

/// A deterministic clock for the timeout tests: hand `{ clock.now() }` to the
/// machine and advance it explicitly.
public final class FakeClock: @unchecked Sendable {
    private var current: Date
    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }
    public func now() -> Date { current }
    public func advance(by interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}
