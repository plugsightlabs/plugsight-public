// MacPermissionDrivers.swift
//
// The REAL macOS implementations of the onboarding driver protocols. These are
// deliberately RUTHLESSLY THIN: each is a direct call into a system API, and
// EVERY decision they inform is made by the pure OnboardingStateMachine, which is
// what the unit tests exercise. Nothing here is CI-tested — these need a real
// login session, TCC, SMAppService, and the packaged .app + .appex to do
// anything — so they are kept as small as the API allows and no logic lives in
// them. They compile on macOS; the checker exercises them on the clean-VM
// walkthrough (07 N11 manual gate).

#if os(macOS)
import Foundation
import AppKit
import CoreGraphics
import ServiceManagement
import SystemExtensions

// MARK: - TCC probing + requesting

/// Input Monitoring via CoreGraphics: preflight to probe without prompting, and
/// the REAL request call that triggers the OS prompt (and lists the app in the
/// Input Monitoring pane) when the machine drives a grant.
public final class MacPermissionProbing: PermissionProbing, @unchecked Sendable {
    public init() {}

    public func inputMonitoringGranted() -> Bool {
        // Preflight does not prompt; the machine uses it for polling.
        CGPreflightListenEventAccess()
    }

    @discardableResult
    public func requestInputMonitoringAccess() -> Bool {
        // Prompts on first ask; afterwards the user flips the toggle in System
        // Settings and the machine's poll sees the grant land.
        CGRequestListenEventAccess()
    }
}

// MARK: - System extension activation

/// Drives an OSSystemExtensionRequest. `bundledExtensionPresent` checks the
/// build actually ships the .systemextension before the machine offers
/// activation; `extensionActive` reflects the last observed outcome; a delegate
/// failure is stored (not dropped) and surfaced via `lastActivationError`.
public final class MacExtensionActivating: NSObject, ExtensionActivating,
                                           OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private let extensionIdentifier: String
    private let queue: DispatchQueue
    private var active: Bool = false
    private var lastError: String?

    public init(extensionIdentifier: String, queue: DispatchQueue = .main) {
        self.extensionIdentifier = extensionIdentifier
        self.queue = queue
    }

    public func bundledExtensionPresent() -> Bool {
        let path = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/Library/SystemExtensions/\(extensionIdentifier).systemextension")
        return FileManager.default.fileExists(atPath: path)
    }

    public func requestActivation() {
        lastError = nil
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: queue)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    public func extensionActive() -> Bool { active }

    public func lastActivationError() -> String? { lastError }

    // OSSystemExtensionRequestDelegate — thin: record outcome only.
    public func request(_ request: OSSystemExtensionRequest,
                        actionForReplacingExtension existing: OSSystemExtensionProperties,
                        withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // Approval happens in System Settings; the state machine already put the
        // step in "Waiting for System Settings".
    }

    public func request(_ request: OSSystemExtensionRequest,
                        didFinishWithResult result: OSSystemExtensionRequest.Result) {
        active = (result == .completed)
        if result != .completed {
            lastError = "Activation finished with an unexpected result (code \(result.rawValue))."
        }
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        active = false
        lastError = error.localizedDescription
    }
}

// MARK: - Login item registration

/// Registers the packaged agent (SMAppService.agent) so plugsightd runs at login.
@available(macOS 13.0, *)
public final class MacLoginItemRegistering: LoginItemRegistering, @unchecked Sendable {
    private let service: SMAppService

    /// - Parameter plistName: the launchd plist bundled in Contents/Library/LaunchAgents.
    public init(plistName: String) {
        self.service = SMAppService.agent(plistName: plistName)
    }

    public func register() throws { try service.register() }

    public func isRegistered() -> Bool { service.status == .enabled }
}

// MARK: - App location check (1d)

/// Is the running app inside /Applications. The move instruction is the exact
/// onboarding copy shown before activation is attempted.
public final class MacAppLocationChecking: AppLocationChecking, @unchecked Sendable {
    private let bundlePath: String
    public let moveInstruction: String

    public init(bundlePath: String = Bundle.main.bundlePath,
                moveInstruction: String =
                    "Plugsight needs to run from your Applications folder. "
                    + "Move it there in Finder, then reopen it to continue.") {
        self.bundlePath = bundlePath
        self.moveInstruction = moveInstruction
    }

    public func isInApplicationsFolder() -> Bool {
        bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix((NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/")
    }
}

// MARK: - System Settings deep-link opener (1b/1c/1e recovery)

/// Hands an `x-apple.systempreferences:` deep link to NSWorkspace so a Grant /
/// Open System Settings button lands the user on the exact privacy pane. Thin by
/// design: the URLs are chosen by the pure machine (degradedConsequence).
public final class MacSystemSettingsOpener: SystemSettingsOpening, @unchecked Sendable {
    public init() {}
    public func open(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}

// MARK: - Scanner availability (daemon-reported)

/// Scanner availability exactly as the daemon reports it: get_status
/// scanner.available, i.e. ClamAV discovery. `refresh` asks the daemon and
/// caches the answer; an unreachable daemon reads as unavailable (honest: no
/// daemon means no on-mount scanning either way).
public final class DaemonScannerAvailability: ScannerAvailabilityChecking, @unchecked Sendable {
    private let api: APIClient
    private let lock = NSLock()
    private var lastKnown = false
    private var lastInstallState: StatusDTO.Scanner.InstallState = .idle
    private var lastInstallDetail: String?

    public init(api: APIClient) { self.api = api }

    public func scannerAvailable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lastKnown
    }

    public func scannerInstallState() -> StatusDTO.Scanner.InstallState {
        lock.lock(); defer { lock.unlock() }
        return lastInstallState
    }

    public func scannerInstallDetail() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastInstallDetail
    }

    public func refresh() async {
        // One status read feeds availability AND the one-click install progress
        // the scanner step polls, so an install lands without a second RPC. The
        // await happens OUT here; the locked write is a synchronous helper, so
        // the lock is never touched from an async context (Swift 6) and never
        // held across a suspension point.
        store((try? await api.getStatus())?.scanner)
    }

    private func store(_ scanner: StatusDTO.Scanner?) {
        lock.lock(); defer { lock.unlock() }
        lastKnown = scanner?.available ?? false
        lastInstallState = scanner?.installState ?? .idle
        lastInstallDetail = scanner?.installDetail
    }
}

// MARK: - One-click scanner install + Terminal fallback

/// The REAL one-click ClamAV install: hands `scanner.install` to the daemon via
/// the shared APIClient. Thin by design; progress is polled through
/// DaemonScannerAvailability. An RPC failure reads as a not-accepted result with
/// the error text, so the step falls back to Terminal instead of dropping it.
public final class DaemonScannerInstalling: ScannerInstalling, @unchecked Sendable {
    private let api: APIClient
    public init(api: APIClient) { self.api = api }
    public func install() async -> ScannerInstallResult {
        do { return try await api.installScanner() }
        catch let e as APIError {
            return ScannerInstallResult(accepted: false, reason: e.message)
        }
        catch {
            return ScannerInstallResult(accepted: false, reason: error.localizedDescription)
        }
    }
}

/// Opens Terminal.app running the install command so the user SEES it run. Uses
/// AppleScript (osascript) to launch Terminal with the command; the app never
/// runs the install silently in the background.
public final class MacTerminalOpening: TerminalOpening, @unchecked Sendable {
    public init() {}
    public func runInTerminal(_ command: String) {
        // Escape backslashes and double quotes for the AppleScript string literal.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\n"
            + "activate\n"
            + "do script \"\(escaped)\"\n"
            + "end tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}

// MARK: - App relaunch (Input Monitoring grants apply on relaunch)

/// Relaunch the app: open a fresh instance of our own bundle, then terminate
/// this one. Used by the Input Monitoring needsAttention guidance, where the
/// grant flipped in System Settings only takes effect in a new process.
public final class MacAppRelaunching: AppRelaunching, @unchecked Sendable {
    public init() {}

    public func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}
#endif
