// SettingsViewModel.swift
//
// The Settings section (04, Wave 3 canvas): three groups — Permissions, Scanner,
// Notifications — each row self-legible in its current state, no global save.
// Canon pressure points: a not-granted permission row shows NUMBERED steps plus
// the exact deep-link button (never a dead end); the system-extension row is
// honest about a build that does not ship the extension ("Not available yet",
// no button); the scanner group speaks plain words, never engine tokens or raw
// day counts; the notification switches are real and their write errors surface
// inline. Jargon never appears on screen.

import Foundation
import PlugsightCore

public enum PermissionRowState: Equatable, Sendable {
    case granted
    /// Installed but not yet approved by the user (ES extension `inactive`): the
    /// user's own action finishes it, so it reads distinctly from "not set up".
    case pending(action: String)   // "Approve in System Settings"
    case missing(action: String)   // "Open System Settings" / "Turn on"
    /// The capability cannot be granted in this build (e.g. the system extension
    /// is not bundled). Text only, NO button: a button would be a dead end.
    case unavailable

    /// The button label for the actionable not-granted states; nil otherwise.
    public var actionLabel: String? {
        switch self {
        case .granted, .unavailable: return nil
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
    /// The System Settings pane this row's button opens, when missing.
    /// Single-sourced from the onboarding machine so Settings and the walk agree.
    public let settingsURL: String?
    /// The numbered what-to-do steps, shown only while the row is actionable and
    /// not granted (canon: the button is a guided action, never a dead end).
    public let steps: [String]
    /// A plain note under a GRANTED row when there is still something worth
    /// knowing (e.g. "the typing check starts after the next daemon restart").
    public let note: String?
    /// An inline plain-language failure line (e.g. the last activation error),
    /// never swallowed, never hover-only.
    public let errorLine: String?
    public init(key: String, title: String, osName: String? = nil, capability: String,
                state: PermissionRowState, settingsURL: String? = nil,
                steps: [String] = [], note: String? = nil, errorLine: String? = nil) {
        self.key = key; self.title = title; self.osName = osName
        self.capability = capability
        self.state = state; self.settingsURL = settingsURL
        self.steps = steps; self.note = note; self.errorLine = errorLine
    }
}

/// The scanner group in plain words. `statusLine` and `definitionsLine` are the
/// exact sentences the row shows; no engine tokens, no raw "N days old" table.
public struct ScannerSection: Equatable, Sendable {
    public let engineFound: Bool
    /// "Malware scanner: ClamAV installed." when found; the guided-install offer
    /// replaces it otherwise.
    public let statusLine: String
    /// "Virus definitions updated today." / "…updated N days ago." /
    /// "Definitions not downloaded yet."
    public let definitionsLine: String
    /// Definitions 7+ days old: the amber "Update recommended" hint shows and the
    /// copyable update command affordance becomes the action.
    public let definitionsStale: Bool
    public let scanOnMount: Bool
    /// When the engine is absent, the guided-install step shows instead.
    public var showsGuidedInstall: Bool { !engineFound }
    public init(engineFound: Bool, statusLine: String, definitionsLine: String,
                definitionsStale: Bool, scanOnMount: Bool) {
        self.engineFound = engineFound
        self.statusLine = statusLine
        self.definitionsLine = definitionsLine
        self.definitionsStale = definitionsStale
        self.scanOnMount = scanOnMount
    }
}

/// The notifications group (04 notification model, Wave 2): the authorization
/// state, the two policy values, and the plain denied hint.
public struct NotificationsSection: Equatable, Sendable {
    public let authorization: NotificationAuthorization
    /// "Notify me when a device looks unsafe" (default on; nil on the wire = on).
    public let notifyUnsafe: Bool
    /// "Also when any new device plugs in" (default off; nil on the wire = off).
    public let notifyNewDevice: Bool
    /// Non-nil iff the user denied notification permission: the plain fix line
    /// (S1b: the promise "you will be notified" is never silently broken).
    public let deniedHint: String?

    public init(authorization: NotificationAuthorization, notifyUnsafe: Bool,
                notifyNewDevice: Bool, deniedHint: String?) {
        self.authorization = authorization
        self.notifyUnsafe = notifyUnsafe
        self.notifyNewDevice = notifyNewDevice
        self.deniedHint = deniedHint
    }

    /// The System Settings pane the denied hint's button opens.
    public static let notificationSettingsURL =
        "x-apple.systempreferences:com.apple.preference.notifications"
    /// The plain denied line, shared so every surface says the same thing.
    public static let deniedHintText =
        "Notifications are off for Plugsight in System Settings. "
        + "Open Notification settings to turn them on."
}

public struct SettingsLoaded: Equatable, Sendable {
    public var permissions: [PermissionRow]
    public var scanner: ScannerSection
    public var notifications: NotificationsSection
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

    /// The stale-definitions fix: ClamAV is already installed, so the recovery is
    /// UPDATING the definitions (freshclam), never a reinstall. Same conf/db-dir
    /// guard as the install command (a manually installed ClamAV may still lack
    /// them), minus the `brew install`. Runs via the same visible-Terminal path.
    public nonisolated static let scannerUpdateCommand =
        "P=\"$(brew --prefix)\" && mkdir -p \"$P/var/lib/clamav\" && "
        + "{ [ -f \"$P/etc/clamav/freshclam.conf\" ] || sed 's/^Example//' "
        + "\"$P/etc/clamav/freshclam.conf.sample\" > \"$P/etc/clamav/freshclam.conf\"; } && freshclam"

    @Published public private(set) var state: SettingsState = .loading
    /// A failed notification-setting write, surfaced as plain text (never a crash).
    @Published public private(set) var notificationsWriteError: String?
    private let api: APIClient
    private let notificationAuthorization: @Sendable () async -> NotificationAuthorization
    /// The SAME guard onboarding uses (does the build ship the .systemextension).
    private let extensionBundled: @Sendable () -> Bool
    /// The most recent extension-activation failure, surfaced inline on the row.
    private let activationError: @Sendable () -> String?

    /// Defaults are the REAL macOS drivers so any shell that constructs this
    /// model gets the honest extension row without extra wiring; tests inject.
    public init(api: APIClient,
                notificationAuthorization: @escaping @Sendable () async -> NotificationAuthorization
                    = { .notDetermined },
                extensionBundled: (@Sendable () -> Bool)? = nil,
                activationError: (@Sendable () -> String?)? = nil) {
        self.api = api
        self.notificationAuthorization = notificationAuthorization
        #if os(macOS)
        self.extensionBundled = extensionBundled ?? {
            MacExtensionActivating(extensionIdentifier: PlugsightIdentifiers.esExtensionBundleID)
                .bundledExtensionPresent()
        }
        self.activationError = activationError ?? {
            MacExtensionActivating.mostRecentActivationError()
        }
        #else
        self.extensionBundled = extensionBundled ?? { true }
        self.activationError = activationError ?? { nil }
        #endif
    }
    public init(previewState: SettingsState) {
        self.api = FakeAPIClient()
        self.notificationAuthorization = { .notDetermined }
        self.extensionBundled = { true }
        self.activationError = { nil }
        self.state = previewState
    }

    /// Persist the "Scan drives when they mount" policy toggle (WP2), then reload
    /// so the Settings surface reflects the daemon's confirmed value.
    public func setScanOnMount(_ on: Bool) async {
        _ = try? await api.setPolicy(scanOnMount: on, holdNewDrives: nil,
                                     notificationThreshold: nil, confirm: true)
        await load()
    }

    /// Persist "Notify me when a device looks unsafe" (notifyUnsafe).
    public func setNotifyUnsafe(_ on: Bool) async {
        await setNotificationPolicy(notifyUnsafe: on, notifyNewDevice: nil)
    }

    /// Persist "Also when any new device plugs in" (notifyNewDevice).
    public func setNotifyNewDevice(_ on: Bool) async {
        await setNotificationPolicy(notifyUnsafe: nil, notifyNewDevice: on)
    }

    public func dismissNotificationsWriteError() { notificationsWriteError = nil }

    /// Write one notification key through policy.set. A daemon that predates the
    /// keys either rejects the write (surfaced verbatim) or echoes the policy
    /// without them; both become a plain sentence, never a crash or silence.
    private func setNotificationPolicy(notifyUnsafe: Bool?, notifyNewDevice: Bool?) async {
        notificationsWriteError = nil
        do {
            let updated = try await api.setPolicy(
                scanOnMount: nil, holdNewDrives: nil, notificationThreshold: nil,
                notifyUnsafe: notifyUnsafe, notifyNewDevice: notifyNewDevice, confirm: true)
            let echoed = (notifyUnsafe != nil && updated.notifyUnsafe != nil)
                || (notifyNewDevice != nil && updated.notifyNewDevice != nil)
            if !echoed {
                notificationsWriteError = "This setting needs a newer version of Plugsight. "
                    + "The change was not saved."
            }
        } catch let e as APIError {
            notificationsWriteError = e.message
        } catch {
            notificationsWriteError = "Plugsight couldn't save this setting. Try again."
        }
        await load()
    }

    /// Build the loaded settings from status + policy + notification
    /// authorization + the two extension facts. Pure so the row states, the
    /// plain scanner sentences, and the notifications degraded state are
    /// unit-testable.
    public static func build(status: StatusDTO, policy: PolicyDTO,
                             notificationAuthorization: NotificationAuthorization = .notDetermined,
                             extensionBundled: Bool = true,
                             activationError: String? = nil)
        -> SettingsLoaded {
        // Permissions — each row states its capability in one plain sentence and,
        // when actionable, carries numbered steps + the exact deep link (1e).
        func url(_ kind: OnboardingStepKind) -> String? {
            OnboardingStateMachine.degradedConsequence(for: kind)?.deepLink?.url
        }
        // Input Monitoring: granted shows the green check + capability sentence;
        // granted-but-sensor-waiting adds the plain restart note; missing shows
        // the numbered steps and the Open System Settings button.
        let imGranted = status.permissions.inputMonitoring
        let imNote: String? = (imGranted && status.permissions.inputMonitoringSensor == "restart_required")
            ? "Granted. The typing check starts after the next daemon restart."
            : nil
        let im = PermissionRow(
            key: "input_monitoring", title: PermissionVocabulary.inputMonitoring.purpose,
            osName: PermissionVocabulary.inputMonitoring.osName,
            capability: InputMonitoringCopy.settingsCapability,
            state: imGranted ? .granted : .missing(action: "Open System Settings"),
            settingsURL: url(.inputMonitoring),
            steps: imGranted ? [] : [
                "Open System Settings with the button below.",
                "Find Plugsight under Input Monitoring.",
                "Switch it on, then come back.",
            ],
            note: imNote)

        // The system extension: honesty first. A build that does not ship the
        // .systemextension gets text and NO button (the same guard onboarding
        // uses); a bundled-but-inactive extension keeps the activation request
        // and surfaces the last activation error inline instead of swallowing it.
        let ext: PermissionRow
        if !extensionBundled {
            ext = PermissionRow(
                key: "system_extension", title: PermissionVocabulary.systemExtension.purpose,
                osName: PermissionVocabulary.systemExtension.osName,
                capability: "Not available yet. Waiting on Apple approval of the monitoring extension.",
                state: .unavailable)
        } else {
            let extState: PermissionRowState
            var extSteps: [String] = []
            switch status.permissions.esExtension {
            case .active:
                extState = .granted
            case .inactive:
                // Activation was requested; macOS is waiting for the user to allow it.
                extState = .pending(action: "Approve in System Settings")
                extSteps = [
                    "Open System Settings with the button below.",
                    "Find Plugsight under Login Items & Extensions.",
                    "Switch it on, then come back.",
                ]
            case .notInstalled:
                extState = .missing(action: "Turn on")
                extSteps = [
                    "Click Turn on below.",
                    "Approve Plugsight in the System Settings window that opens.",
                    "Come back here.",
                ]
            }
            ext = PermissionRow(
                key: "system_extension", title: PermissionVocabulary.systemExtension.purpose,
                osName: PermissionVocabulary.systemExtension.osName,
                capability: "Adds higher-fidelity monitoring and lets Plugsight hold new drives until scanned.",
                state: extState, settingsURL: url(.systemExtension),
                steps: extSteps, errorLine: extState == .granted ? nil : activationError)
        }
        // WP2: the vestigial Full Disk Access row is gone. FDA is not used at
        // runtime; scanning works on /Volumes without it.

        // Scanner — plain sentences only. nil age is honest: not downloaded yet.
        let definitionsLine: String
        var stale = false
        if let days = status.scanner.definitionsAgeDays {
            switch days {
            case 0: definitionsLine = "Virus definitions updated today."
            case 1: definitionsLine = "Virus definitions updated 1 day ago."
            default: definitionsLine = "Virus definitions updated \(days) days ago."
            }
            stale = days >= 7
        } else {
            definitionsLine = "Definitions not downloaded yet."
        }
        let scanner = ScannerSection(
            engineFound: status.scanner.available,
            statusLine: "Malware scanner: ClamAV installed.",
            definitionsLine: definitionsLine, definitionsStale: stale,
            scanOnMount: policy.scanOnMount)

        // Notifications (Wave 2): the two policy values with their nil defaults
        // (nil notifyUnsafe = on, nil notifyNewDevice = off) and the visible
        // degraded state when the user denied permission (S1b).
        let notifications = NotificationsSection(
            authorization: notificationAuthorization,
            notifyUnsafe: policy.notifyUnsafe ?? true,
            notifyNewDevice: policy.notifyNewDevice ?? false,
            deniedHint: notificationAuthorization == .denied
                ? NotificationsSection.deniedHintText : nil)

        return SettingsLoaded(permissions: [im, ext], scanner: scanner,
                              notifications: notifications)
    }

    public func load() async {
        do {
            let status = try await api.getStatus()
            let policy = try await api.getPolicy()
            let auth = await notificationAuthorization()
            state = .loaded(Self.build(status: status, policy: policy,
                                       notificationAuthorization: auth,
                                       extensionBundled: extensionBundled(),
                                       activationError: activationError()))
        } catch let e as APIError {
            state = .storeError(message: e.message)
        } catch {
            state = .storeError(message: "Can't read settings")
        }
    }
}
