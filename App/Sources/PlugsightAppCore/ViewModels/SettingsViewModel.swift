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
    /// Installed but not yet approved by the user (ES extension `inactive`): the
    /// user's own action finishes it, so it reads distinctly from "not set up".
    case pending(action: String)   // "Approve in System Settings"
    case missing(action: String)   // "Grant" / "Turn on"

    /// The button label for the not-granted states; nil when granted.
    public var actionLabel: String? {
        switch self {
        case .granted: return nil
        case .pending(let a), .missing(let a): return a
        }
    }
}

public struct PermissionRow: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String         // purpose-led (WP2): what it does for you
    public let osName: String?       // the OS permission name, secondary (WP2)
    public let capability: String   // one sentence: what it enables
    public let state: PermissionRowState
    /// The System Settings pane this row's Grant/Open button opens, when missing.
    /// Single-sourced from the onboarding machine so Settings and the walk agree.
    public let settingsURL: String?
    /// One always-visible line telling the user what to do after the button, shown
    /// only while the row is not granted. Turns "Open System Settings" from a dead
    /// end into a guided step (canon: errors/actions say the one thing that recovers).
    public let hint: String?
    public init(key: String, title: String, osName: String? = nil, capability: String,
                state: PermissionRowState, settingsURL: String? = nil, hint: String? = nil) {
        self.key = key; self.title = title; self.osName = osName
        self.capability = capability
        self.state = state; self.settingsURL = settingsURL; self.hint = hint
    }
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
    /// The exact install fix surfaced in Settings, the onboarding Terminal
    /// fallback, and scan errors (05). Installs ClamAV via Homebrew AND pulls the
    /// virus definitions in one copyable line, so the scanner is ready to use.
    /// A fresh brew ClamAV ships only freshclam.conf.sample (whose Example line
    /// makes freshclam refuse to run) and no database dir, so a bare `freshclam`
    /// fails on a clean install. This resolves the brew prefix, ensures the
    /// database dir and a real freshclam.conf (created from the sample with
    /// Example stripped when missing, never clobbering an existing one), then
    /// runs freshclam.
    public nonisolated static let scannerInstallCommand =
        "brew install clamav && P=\"$(brew --prefix)\" && mkdir -p \"$P/var/lib/clamav\" && "
        + "{ [ -f \"$P/etc/clamav/freshclam.conf\" ] || sed 's/^Example//' "
        + "\"$P/etc/clamav/freshclam.conf.sample\" > \"$P/etc/clamav/freshclam.conf\"; } && freshclam"

    @Published public private(set) var state: SettingsState = .loading
    private let api: APIClient
    public init(api: APIClient) { self.api = api }
    public init(previewState: SettingsState) { self.api = FakeAPIClient(); self.state = previewState }

    /// Persist the "Scan drives when they mount" policy toggle (WP2), then reload
    /// so the Settings surface reflects the daemon's confirmed value.
    public func setScanOnMount(_ on: Bool) async {
        _ = try? await api.setPolicy(scanOnMount: on, holdNewDrives: nil,
                                     notificationThreshold: nil, confirm: true)
        await load()
    }

    /// Build the loaded settings from status + policy. Pure so the gating and
    /// the "unknown"/stale definitions states are unit-testable.
    public static func build(status: StatusDTO, policy: PolicyDTO) -> SettingsLoaded {
        // Permissions — each row states its capability in one plain sentence.
        // Deep-link URLs come from the onboarding machine's single source, so the
        // Settings re-grant buttons open the SAME panes the walk does (1e).
        func url(_ kind: OnboardingStepKind) -> String? {
            OnboardingStateMachine.degradedConsequence(for: kind)?.deepLink?.url
        }
        // Purpose-led titles (WP2): the friendly purpose leads, the OS permission
        // name is the secondary line. The Input Monitoring capability is reframed
        // honestly: timing-only, keys never read, nothing leaves the Mac.
        let im = PermissionRow(
            key: "input_monitoring", title: PermissionVocabulary.inputMonitoring.purpose,
            osName: PermissionVocabulary.inputMonitoring.osName,
            capability: InputMonitoringCopy.settingsCapability,
            state: status.permissions.inputMonitoring ? .granted : .missing(action: "Grant"),
            settingsURL: url(.inputMonitoring))
        // The extension has THREE real states, and the app knows which one it is
        // (status.get). Collapsing "installed, waiting for your approval" and "not
        // set up" into one orange row hid the difference the user needs; each state
        // now carries its own icon (in the view), button label, and inline step.
        let extState: PermissionRowState
        let extHint: String?
        switch status.permissions.esExtension {
        case .active:
            extState = .granted
            extHint = nil
        case .inactive:
            // Activation was requested; macOS is waiting for the user to allow it.
            extState = .pending(action: "Approve in System Settings")
            extHint = "Almost there. In the window that opens, switch Plugsight on under "
                + "Login Items & Extensions, then come back here."
        case .notInstalled:
            extState = .missing(action: "Turn on")
            extHint = "Turns on higher-fidelity monitoring. You approve it once, in "
                + "System Settings."
        }
        let ext = PermissionRow(
            key: "system_extension", title: PermissionVocabulary.systemExtension.purpose,
            osName: PermissionVocabulary.systemExtension.osName,
            capability: "Adds higher-fidelity monitoring and lets Plugsight hold new drives until scanned.",
            state: extState, settingsURL: url(.systemExtension), hint: extHint)
        // WP2: the vestigial Full Disk Access row is gone. FDA is not used at
        // runtime; scanning works on /Volumes without it.

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

        return SettingsLoaded(permissions: [im, ext], scanner: scanner, protection: protection)
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
