// MacPermissionDrivers.swift
//
// The REAL macOS implementations of the four onboarding driver protocols. These
// are deliberately RUTHLESSLY THIN: each is a direct call into a system API, and
// EVERY decision they inform is made by the pure OnboardingStateMachine, which is
// what the unit tests exercise. Nothing here is CI-tested — these need a real
// login session, TCC, SMAppService, and the packaged .app + .appex to do
// anything — so they are kept as small as the API allows and no logic lives in
// them. They compile on macOS; the checker exercises them on the clean-VM
// walkthrough (07 N11 manual gate).

#if os(macOS)
import Foundation
import CoreGraphics
import ServiceManagement
import SystemExtensions

// MARK: - TCC probing

/// Input Monitoring via CoreGraphics preflight; Full Disk Access via a probe read
/// of a TCC-protected path (there is no public FDA API, 02's known rough edge).
public final class MacPermissionProbing: PermissionProbing, @unchecked Sendable {
    private let fdaProbePath: String
    public init(fdaProbePath: String =
                    (NSHomeDirectory() as NSString)
                        .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")) {
        self.fdaProbePath = fdaProbePath
    }

    public func inputMonitoringGranted() -> Bool {
        // Preflight does not prompt; the prompt is triggered by starting the tap.
        CGPreflightListenEventAccess()
    }

    public func fullDiskAccessGranted() -> Bool {
        // Readability of a TCC-protected path is the standard heuristic: it only
        // succeeds when Full Disk Access is granted.
        FileManager.default.isReadableFile(atPath: fdaProbePath)
    }
}

// MARK: - System extension activation

/// Drives an OSSystemExtensionRequest. `extensionActive` reflects the last
/// observed outcome; the state machine polls it after `requestActivation`.
public final class MacExtensionActivating: NSObject, ExtensionActivating,
                                           OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private let extensionIdentifier: String
    private let queue: DispatchQueue
    private var active: Bool = false

    public init(extensionIdentifier: String, queue: DispatchQueue = .main) {
        self.extensionIdentifier = extensionIdentifier
        self.queue = queue
    }

    public func requestActivation() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: queue)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    public func extensionActive() -> Bool { active }

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
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        active = false
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
#endif
