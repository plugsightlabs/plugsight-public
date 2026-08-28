// FakeOnboardingDrivers.swift
//
// Fakes for the four onboarding driver protocols, so the pure state machine is
// exercised without TCC, SMAppService, the ES extension, or being in
// /Applications. Each fake is a mutable class the tests toggle to simulate a
// grant landing, a denial, or a mislocated app. Shipped in the library's
// Testing/ folder (like FakeAPIClient) so both the unit tests and previews can
// drive the machine deterministically.

import Foundation

public final class FakePermissionProbing: PermissionProbing, @unchecked Sendable {
    public var inputMonitoring: Bool
    public var fullDiskAccess: Bool
    public init(inputMonitoring: Bool = false, fullDiskAccess: Bool = false) {
        self.inputMonitoring = inputMonitoring
        self.fullDiskAccess = fullDiskAccess
    }
    public func inputMonitoringGranted() -> Bool { inputMonitoring }
    public func fullDiskAccessGranted() -> Bool { fullDiskAccess }
}

public final class FakeExtensionActivating: ExtensionActivating, @unchecked Sendable {
    public var active: Bool
    /// How many times activation was actually driven — the location-gate tests
    /// assert this stays 0 when the app is mislocated (1d).
    public private(set) var activationRequests = 0
    public init(active: Bool = false) { self.active = active }
    public func requestActivation() { activationRequests += 1 }
    public func extensionActive() -> Bool { active }
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
