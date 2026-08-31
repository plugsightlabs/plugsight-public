// MainWindowView.swift
//
// The single main window (04 navigation): a sidebar with exactly three items —
// Timeline, Devices, Settings — and, for Devices, the device inspector opens as a
// pane inside the window (never a modal), so peers stay navigable. This is the
// live composition; each pane is a tested view model feeding its surface view.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public enum MainSection: String, CaseIterable, Identifiable, Sendable {
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
}

public struct MainWindowView: View {
    @StateObject private var timeline: TimelineViewModel
    @StateObject private var devices: DevicesViewModel
    @StateObject private var settings: SettingsViewModel
    @State private var section: MainSection
    @State private var selectedDevice: String?

    private let api: APIClient
    #if os(macOS)
    // Held for the view's lifetime so the OS activation request's delegate is not
    // deallocated mid-approval. Same extension identifier as the onboarding walk.
    private let extensionActivator = MacExtensionActivating(extensionIdentifier: "com.plugsight.esextension")
    #endif

    public init(api: APIClient, initialSection: MainSection = .timeline) {
        self.api = api
        _section = State(initialValue: initialSection)
        _timeline = StateObject(wrappedValue: TimelineViewModel(api: api))
        _devices = StateObject(wrappedValue: DevicesViewModel(api: api))
        _settings = StateObject(wrappedValue: SettingsViewModel(api: api))
    }

    public var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.systemImage).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            detail
        }
        .task { await refresh() }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .timeline:
            TimelineView(state: timeline.state)
        case .devices:
            HStack(spacing: 0) {
                DevicesView(state: devices.state,
                            selectedId: selectedDevice,
                            onSelect: { selectedDevice = $0 })
                    .frame(minWidth: 320)
                Divider()
                if let id = selectedDevice {
                    InspectorHost(api: api, deviceId: id)
                        .frame(minWidth: 340)
                } else {
                    Text("Select a device").foregroundStyle(.secondary)
                        .frame(minWidth: 340, maxHeight: .infinity)
                }
            }
        case .settings:
            SettingsView(state: settings.state, actions: settingsActions)
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
            setScanOnMount: { on in Task { await settings.setScanOnMount(on) } })
        #else
        return .inert
        #endif
    }

    private func refresh() async {
        await timeline.load()
        await devices.load()
        await settings.load()
    }
}

/// Hosts one device inspector, loading it when the selection changes.
struct InspectorHost: View {
    let api: APIClient
    let deviceId: String
    @StateObject private var vm: DeviceInspectorViewModel

    init(api: APIClient, deviceId: String) {
        self.api = api; self.deviceId = deviceId
        _vm = StateObject(wrappedValue: DeviceInspectorViewModel(api: api, deviceId: deviceId))
    }
    var body: some View {
        DeviceInspectorView(
            state: vm.state,
            undoToast: vm.undoToast,
            trustWriteError: vm.trustWriteError,
            onSetTrust: { tier in Task { await vm.setTrust(tier) } },
            onUndo: { Task { await vm.undoTrust() } },
            onDismissUndo: { vm.dismissUndo() },
            onDismissError: { vm.dismissTrustWriteError() })
            .task(id: deviceId) { await vm.load() }
    }
}
