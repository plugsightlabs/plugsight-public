// SettingsViewModel.swift
//
// The Settings section (04): three groups, each row self-legible in its current
// state, no global save. The canon pressure points: the "Hold new drives until
// scanned" toggle is DISABLED with an INLINE reason (never hover-only) when its
// prerequisites are missing (8b); the definitions age renders "unknown" as its
// own muted state; the notification threshold picker's options describe
// themselves. Jargon never appears ("Hold new drives until scanned", not
// "mount-hold").

import Foundation

public enum PermissionRowState: Equatable, Sendable {
    case granted
    case missing(action: String)   // "Grant" / "Open System Settings"
}

public struct PermissionRow: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let capability: String   // one sentence: what it enables
    public let state: PermissionRowState
}

/// The scanner group. Definitions age is null-safe: nil → "unknown" muted state.
public struct ScannerSection: Equatable, Sendable {
    public let engineFound: Bool
    public let engineName: String?
    public let definitionsAgeText: String   // "2 days old" | "unknown" | "…stale…"
    public let definitionsStale: Bool
    public let scanOnMount: Bool
    /// When the engine is absent, the guided-install step shows instead.
    public var showsGuidedInstall: Bool { !engineFound }
}

/// A control that may be disabled, always carrying its reason as visible text.
public struct GatedToggle: Equatable, Sendable {
    public let isOn: Bool
    public let enabled: Bool
    /// Non-nil iff disabled — rendered inline, never hover-only (8b).
    public let disabledReason: String?
}

public struct ProtectionSection: Equatable, Sendable {
    public let holdNewDrives: GatedToggle
    public let notificationThresholdWire: String
    public let thresholdOptions: [SeverityVocabulary.ThresholdOption]
    public var notificationThresholdLabel: String {
        SeverityVocabulary.thresholdLabel(forWire: notificationThresholdWire)
    }
}

public struct SettingsLoaded: Equatable, Sendable {
    public var permissions: [PermissionRow]
    public var scanner: ScannerSection
    public var protection: ProtectionSection
}

public enum SettingsState: Equatable, Sendable {
    case loading
    case loaded(SettingsLoaded)
    case storeError(message: String)
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public private(set) var state: SettingsState = .loading
    private let api: APIClient
    public init(api: APIClient) { self.api = api }
    public init(previewState: SettingsState) { self.api = FakeAPIClient(); self.state = previewState }

    /// Build the loaded settings from status + policy. Pure so the gating and
    /// the "unknown"/stale definitions states are unit-testable.
    public static func build(status: StatusDTO, policy: PolicyDTO) -> SettingsLoaded {
        // Permissions — each row states its capability in one plain sentence.
        let im = PermissionRow(
            key: "input_monitoring", title: "Input Monitoring",
            capability: "Lets Plugsight score typing behavior to spot keystroke-injection attacks.",
            state: status.permissions.inputMonitoring ? .granted : .missing(action: "Grant"))
        let ext = PermissionRow(
            key: "system_extension", title: "System Extension",
            capability: "Adds higher-fidelity monitoring and lets Plugsight hold new drives until scanned.",
            state: status.permissions.esExtension == .active
                ? .granted : .missing(action: "Open System Settings"))
        let fda = PermissionRow(
            key: "full_disk_access", title: "Full Disk Access",
            capability: "Lets the scanner read files on drives you plug in.",
            state: status.scanner.available ? .granted : .missing(action: "Grant"))

        // Scanner — definitions age is null-safe: nil renders as "unknown".
        let ageText: String
        var stale = false
        if let days = status.scanner.definitionsAgeDays {
            ageText = days == 1 ? "1 day old" : "\(days) days old"
            stale = days >= 7
        } else {
            ageText = "unknown"
        }
        let scanner = ScannerSection(
            engineFound: status.scanner.available,
            engineName: status.scanner.engine,
            definitionsAgeText: ageText, definitionsStale: stale,
            scanOnMount: policy.scanOnMount)

        // Protection — Hold new drives requires the extension AND a scanner. The
        // reason is inline text naming the exact missing prerequisite (8b).
        let prereqOK = status.permissions.esExtension == .active && status.scanner.available
        var reason: String?
        if !prereqOK {
            if status.permissions.esExtension != .active {
                reason = "Needs the system extension; activate it above."
            } else {
                reason = "Needs a scanner; install one in the Scanner section above."
            }
        }
        let hold = GatedToggle(
            isOn: policy.holdUntilScanned && prereqOK,
            enabled: prereqOK, disabledReason: reason)
        let protection = ProtectionSection(
            holdNewDrives: hold,
            notificationThresholdWire: policy.notificationThreshold,
            thresholdOptions: SeverityVocabulary.thresholdOptions)

        return SettingsLoaded(permissions: [im, ext, fda], scanner: scanner, protection: protection)
    }

    public func load() async {
        do {
            let status = try await api.getStatus()
            let policy = try await api.getPolicy()
            state = .loaded(Self.build(status: status, policy: policy))
        } catch let e as APIError {
            state = .storeError(message: e.message)
        } catch {
            state = .storeError(message: "Can't read settings")
        }
    }
}
