// SettingsView.swift
//
// The Settings section (04): three groups, each row self-legible, no global save.
// The disabled "Hold new drives until scanned" toggle shows its reason as inline
// text, never hover-only (8b). Definitions age renders "unknown" as its own muted
// state. The threshold picker's options describe themselves.

import SwiftUI

/// Settings recovery wiring. Snapshot rendering passes `.inert` (the default) so
/// the static gallery renders states without a live shell.
public struct SettingsActions {
    /// Open a System Settings deep link (the permission-row Grant / Open button).
    public let openSystemSettings: (String) -> Void
    /// Submit the system-extension activation request, so macOS shows its own
    /// guided approval prompt that lands on the exact toggle (the extension row's
    /// button, instead of a bare deep link that dead-ends the user on a pane).
    public let activateExtension: () -> Void
    /// Copy the scanner install command to the clipboard (5c guided install).
    public let copyInstallCommand: () -> Void
    /// Open Terminal.app running the ClamAV install command (WP2 fallback).
    public let installInTerminal: () -> Void
    /// Persist the "Scan drives when they mount" toggle (WP2).
    public let setScanOnMount: (Bool) -> Void
    public init(openSystemSettings: @escaping (String) -> Void = { _ in },
                activateExtension: @escaping () -> Void = {},
                copyInstallCommand: @escaping () -> Void = {},
                installInTerminal: @escaping () -> Void = {},
                setScanOnMount: @escaping (Bool) -> Void = { _ in }) {
        self.openSystemSettings = openSystemSettings
        self.activateExtension = activateExtension
        self.copyInstallCommand = copyInstallCommand
        self.installInTerminal = installInTerminal
        self.setScanOnMount = setScanOnMount
    }
    public static let inert = SettingsActions()
}

public struct SettingsView: View {
    let state: SettingsState
    let actions: SettingsActions
    public init(state: SettingsState, actions: SettingsActions = .inert) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        switch state {
        case .loading:
            VStack { ForEach(0..<4, id: \.self) { _ in skeleton } }.padding(PS.s4)
        case .storeError(let msg):
            PSStoreError(message: msg)
        case .loaded(let l):
            PSScroll {
                VStack(alignment: .leading, spacing: PS.s5) {
                    group("Permissions") {
                        ForEach(l.permissions) { permissionRow($0) }
                        // Persistent trust reassurance in the permissions area (WP2).
                        Label(TrustCopy.stayOnMac, systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    group("Scanner") { scannerSection(l.scanner) }
                    group("Protection") { protectionSection(l.protection) }
                }
                .padding(PS.s4)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PS.s3) {
            Text(title).font(.headline)
            content()
        }
    }

    private func permissionRow(_ r: PermissionRow) -> some View {
        HStack(alignment: .top, spacing: PS.s3) {
            Image(systemName: iconFor(r.state))
                .foregroundStyle(colorFor(r.state)).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.callout.weight(.medium))
                // The OS permission name, secondary under the purpose-led title (WP2).
                if let osName = r.osName {
                    Text(osName).font(.caption2).foregroundStyle(.secondary)
                }
                Text(r.capability).font(.caption).foregroundStyle(.secondary)
                // The always-visible next step, so the button is a guided action
                // rather than a dead end (shown only while not granted).
                if let hint = r.hint, r.state.actionLabel != nil {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let label = r.state.actionLabel {
                Button(label) { performAction(r) }.controlSize(.small)
            }
        }
        .frame(minHeight: PS.rowHeight)
    }

    /// The extension row triggers the OS activation request (macOS then shows its
    /// own guided Approve prompt); every other row opens its System Settings pane.
    private func performAction(_ r: PermissionRow) {
        if r.key == "system_extension" {
            actions.activateExtension()
        } else if let url = r.settingsURL {
            actions.openSystemSettings(url)
        }
    }

    private func scannerSection(_ s: ScannerSection) -> some View {
        VStack(alignment: .leading, spacing: PS.s3) {
            // The simple "why" for ClamAV, present in Settings too (WP2).
            Text(ScannerCopy.explanationBody)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if s.showsGuidedInstall {
                Label("No scanner found. Install one to scan drives on mount.",
                      systemImage: "arrow.down.circle")
                    .font(.callout)
                // The exact install fix, surfaced (05) rather than a dead button:
                // the command is shown and copyable, plus a Terminal fallback that
                // opens Terminal.app running it so the user sees it run (WP2).
                HStack(spacing: PS.s2) {
                    Text(SettingsViewModel.scannerInstallCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, PS.s2).padding(.vertical, PS.s1)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy", action: actions.copyInstallCommand).controlSize(.small)
                    Button("Install in Terminal", action: actions.installInTerminal).controlSize(.small)
                }
            } else {
                HStack {
                    Text("Engine").font(.callout)
                    Spacer()
                    Text(s.engineName ?? "Found").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Definitions").font(.callout)
                Spacer()
                Text(s.definitionsAgeText)
                    .font(.callout)
                    .foregroundStyle(s.definitionsAgeText == "unknown" || s.definitionsStale
                                     ? .secondary : .primary)
                if s.definitionsStale {
                    Text("update recommended").font(.caption2).foregroundStyle(.orange)
                }
            }
            PSToggleRow("Scan drives when they mount", isOn: s.scanOnMount,
                        onToggle: actions.setScanOnMount)
        }
    }

    private func protectionSection(_ p: ProtectionSection) -> some View {
        VStack(alignment: .leading, spacing: PS.s3) {
            VStack(alignment: .leading, spacing: PS.s1) {
                PSToggleRow("Hold new drives until scanned",
                            isOn: p.holdNewDrives.isOn, enabled: p.holdNewDrives.enabled)
                if let reason = p.holdNewDrives.disabledReason {
                    // Inline reason, always visible — never hover-only (8b).
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: PS.s1) {
                Text("Notify me about").font(.callout.weight(.medium))
                PSRadioGroup(options: p.thresholdOptions.map { ($0.wire, $0.label) },
                             selected: p.notificationThresholdWire)
            }
        }
    }

    private func iconFor(_ s: PermissionRowState) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"   // on
        case .pending: return "clock.badge.checkmark"   // waiting on your approval
        case .missing: return "exclamationmark.circle"  // action needed / not set up
        }
    }
    private func colorFor(_ s: PermissionRowState) -> Color {
        if case .granted = s { return .green }
        return .orange
    }
    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 30)
    }
}
