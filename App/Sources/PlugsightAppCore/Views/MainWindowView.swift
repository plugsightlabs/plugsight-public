// MainWindowView.swift
//
// The single main window (04 navigation): a sidebar with exactly three items —
// Timeline, Devices, Settings — and, for Devices, the device inspector opens as a
// pane inside the window (never a modal), so peers stay navigable. This is the
// live composition; each pane is a tested view model feeding its surface view.

import SwiftUI

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
    @State private var section: MainSection = .timeline
    @State private var selectedDevice: String?

    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
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
            SettingsView(state: settings.state)
        }
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
