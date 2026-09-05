// MainWindowView.swift
//
// The single main window (04 IA): a sidebar with exactly two items — Devices
// and Settings — and, for Devices, the device inspector opens as a pane inside
// the window (never a modal), so peers stay navigable. The event history lives
// behind the quiet Activity link on the Devices home (S10a) and presents as a
// sheet; it is deliberately not a sidebar tab. This is the live composition;
// each pane is a tested view model feeding its surface view.

import SwiftUI
import Combine
import PlugsightCore
#if canImport(AppKit)
import AppKit
#endif

public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    /// Retained for source compatibility with the shell's openMainWindow
    /// callers; the Timeline tab itself is deleted (04 IA), so this section
    /// renders the Devices home.
    case timeline = "Timeline"
    case devices = "Devices"
    case settings = "Settings"
    public var id: String { rawValue }
    public var systemImage: String {
        switch self {
        case .timeline: return "clock"
        case .devices: return "cable.connector"
        case .settings: return "gearshape"
        }
    }
    /// The sidebar's two sections (04): Devices + Settings, nothing else.
    public static let sidebar: [MainSection] = [.devices, .settings]
}

public extension Notification.Name {
    /// Posted (userInfo: ["deviceId": String]) to land the main window on the
    /// Devices home with that device selected — the popover's Details path (S9b).
    static let plugsightOpenDevice = Notification.Name("plugsight.openDevice")
}

public struct MainWindowView: View {
    @StateObject private var timeline: TimelineViewModel
    @StateObject private var devices: DevicesViewModel
    @StateObject private var settings: SettingsViewModel
    @State private var section: MainSection
    @State private var selectedDevice: String?
    @State private var showActivity = false

    private let api: APIClient
    /// The live refresh signal (Wave 2): each debounced tick from the event
    /// stream reloads Devices/Settings (and Activity while open), so the window
    /// never freezes on its first load. nil (tests, previews) means
    /// load-on-appear only.
    private let liveRefresh: RefreshCoordinator?
    #if os(macOS)
    // Held for the view's lifetime so the OS activation request's delegate is not
    // deallocated mid-approval. Same extension identifier as the onboarding walk.
    private let extensionActivator = MacExtensionActivating(extensionIdentifier: PlugsightIdentifiers.esExtensionBundleID)
    #endif

    public init(api: APIClient, initialSection: MainSection = .devices,
                refresh: RefreshCoordinator? = nil,
                notificationAuthorization: (@Sendable () async -> NotificationAuthorization)? = nil) {
        self.api = api
        self.liveRefresh = refresh
        // The Timeline tab no longer exists; a caller asking for it lands on
        // the Devices home (where the Activity link lives).
        _section = State(initialValue: initialSection == .timeline ? .devices : initialSection)
        _timeline = StateObject(wrappedValue: TimelineViewModel(api: api))
        _devices = StateObject(wrappedValue: DevicesViewModel(api: api))
        _settings = StateObject(wrappedValue: SettingsViewModel(
            api: api, notificationAuthorization: notificationAuthorization ?? { .notDetermined }))
    }

    /// The tick stream this window reloads on; empty when no coordinator is wired.
    private var refreshTicks: AnyPublisher<Int, Never> {
        liveRefresh?.$tick.dropFirst().eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    }

    /// FIXED layout geometry (owner directive after the live walk: no elastic
    /// panes). The sidebar and inspector have constant widths, the device list
    /// takes the rest, and the window's hard minimum is the exact sum of the
    /// fixed parts plus the list's honest minimum, so no width ever reflows
    /// the panes into a broken state (floating sidebar, vanished name column).
    public static let sidebarWidth: CGFloat = 180
    public static let inspectorWidth: CGFloat = 360
    /// sidebar + divider + device list minimum + divider + inspector.
    public static let minContentSize = CGSize(
        width: sidebarWidth + 1 + DevicesView.paneMinWidth + 1 + inspectorWidth,
        height: 520)

    public var body: some View {
        // A plain HStack, deliberately: NavigationSplitView floated its sidebar
        // OVER the content whenever the window was narrower than the panes'
        // combined minimums. A fixed sidebar always occupies its own space and
        // can never collapse, float, or overlay.
        HStack(spacing: 0) {
            List(MainSection.sidebar, selection: $section) { s in
                Label(s.rawValue, systemImage: s.systemImage).tag(s)
            }
            .listStyle(.sidebar)
            .frame(width: Self.sidebarWidth)
            Divider()
            detail
        }
        .task { await reloadAll() }
        .onReceive(refreshTicks) { _ in Task { await reloadAll() } }
        // The popover's alert rows post this to open the window at a device.
        .onReceive(NotificationCenter.default.publisher(for: .plugsightOpenDevice)) { note in
            guard let id = note.userInfo?["deviceId"] as? String else { return }
            section = .devices
            selectedDevice = id
        }
        .sheet(isPresented: $showActivity) {
            ActivityView(state: timeline.state,
                         alertsOnly: timeline.filters.activeAlertsOnly,
                         onToggleAlertsOnly: { on in
                             timeline.filters.activeAlertsOnly = on
                             Task { await timeline.load() }
                         },
                         onClose: { showActivity = false },
                         onOpenDevice: { id in
                             // Navigate: close the sheet, land on the device.
                             showActivity = false
                             section = .devices
                             selectedDevice = id
                         })
                .frame(minWidth: 560, minHeight: 460)
                .task { await timeline.load() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .devices, .timeline:
            HStack(spacing: 0) {
                DevicesView(state: devices.state,
                            selectedId: selectedDevice,
                            onSelect: { selectedDevice = $0 },
                            onOpenActivity: { showActivity = true },
                            onRetry: { Task { await devices.load() } })
                    .frame(minWidth: DevicesView.paneMinWidth, maxWidth: .infinity)
                Divider()
                if let id = selectedDevice {
                    // .id(id) resets the host's StateObject when the selection
                    // changes; without it the persisted view model kept loading
                    // the FIRST selected device forever.
                    InspectorHost(api: api, deviceId: id)
                        .id(id)
                        .frame(width: Self.inspectorWidth)
                } else {
                    Text("Select a device").foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                        .frame(width: Self.inspectorWidth)
                }
            }
        case .settings:
            SettingsView(state: settings.state, actions: settingsActions,
                         notificationsWriteError: settings.notificationsWriteError,
                         onRetry: { Task { await settings.load() } })
        }
    }

    /// Real recovery wiring for Settings: Grant/Open buttons hand their pane URL
    /// to NSWorkspace; Copy puts the scanner install command on the clipboard.
    private var settingsActions: SettingsActions {
        #if os(macOS)
        let opener = MacSystemSettingsOpener()
        let terminal = MacTerminalOpening()
        return SettingsActions(
            openSystemSettings: { opener.open($0) },
            activateExtension: { [extensionActivator] in extensionActivator.requestActivation() },
            copyInstallCommand: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SettingsViewModel.scannerInstallCommand, forType: .string)
            },
            installInTerminal: { terminal.runInTerminal(SettingsViewModel.scannerInstallCommand) },
            updateDefinitionsInTerminal: { terminal.runInTerminal(SettingsViewModel.scannerUpdateCommand) },
            setScanOnMount: { on in Task { await settings.setScanOnMount(on) } },
            setNotifyUnsafe: { on in Task { await settings.setNotifyUnsafe(on) } },
            setNotifyNewDevice: { on in Task { await settings.setNotifyNewDevice(on) } })
        #else
        return .inert
        #endif
    }

    private func reloadAll() async {
        await devices.load()
        await settings.load()
        // The Activity sheet stays fresh while it is open; otherwise it loads
        // on presentation.
        if showActivity { await timeline.load() }
    }
}

/// Hosts one device inspector, loading it when the selection changes. All the
/// inspector's verdict actions run through the view model (async call, inline
/// error on failure, refresh after success); the Input Monitoring deep link is
/// the one OS-level action, injected here like the Settings openers.
struct InspectorHost: View {
    let api: APIClient
    let deviceId: String
    @StateObject private var vm: DeviceInspectorViewModel

    init(api: APIClient, deviceId: String) {
        self.api = api; self.deviceId = deviceId
        _vm = StateObject(wrappedValue: DeviceInspectorViewModel(api: api, deviceId: deviceId))
    }

    private func openInputMonitoring() {
        #if os(macOS)
        MacSystemSettingsOpener()
            .open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        #endif
    }

    var body: some View {
        DeviceInspectorView(
            state: vm.state,
            undoToast: vm.undoToast,
            trustWriteError: vm.trustWriteError,
            actionError: vm.actionError,
            onSetTrust: { tier in Task { await vm.setTrust(tier) } },
            onUndo: { Task { await vm.undoTrust() } },
            onDismissUndo: { vm.dismissUndo() },
            onDismissError: { vm.dismissTrustWriteError() },
            onDismissActionError: { vm.dismissActionError() },
            onScanNow: { Task { await vm.scanNow() } },
            onCancelScan: { id in Task { await vm.cancelScan(scanId: id) } },
            onRestoreQuarantine: { id in Task { await vm.restoreQuarantine(quarantineId: id) } },
            onAcknowledgeAlert: { id in Task { await vm.acknowledgeAlert(alertId: id) } },
            onOpenInputMonitoring: { openInputMonitoring() },
            onRetry: { Task { await vm.load() } })
            .task(id: deviceId) { await vm.load() }
    }
}
