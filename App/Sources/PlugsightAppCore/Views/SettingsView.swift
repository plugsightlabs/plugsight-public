// SettingsView.swift
//
// The Settings section (04, Wave 3 canvas): three groups — Permissions, Scanner,
// Notifications — each row self-legible, no global save. A granted permission
// shows a green check + one capability sentence; a missing one shows numbered
// steps and the exact deep-link button; an unavailable one (unbundled extension)
// shows honest text and NO button. The scanner speaks plain sentences; the
// notification switches are real and their write errors render inline.

import SwiftUI

/// Settings recovery wiring. Snapshot rendering passes `.inert` (the default) so
/// the static gallery renders states without a live shell.
public struct SettingsActions {
    /// Open a System Settings deep link (permission rows + the denied
    /// notifications hint's Open Notification Settings button).
    public let openSystemSettings: (String) -> Void
    /// Submit the system-extension activation request, so macOS shows its own
    /// guided approval prompt that lands on the exact toggle (the extension row's
    /// button, instead of a bare deep link that dead-ends the user on a pane).
    public let activateExtension: () -> Void
    /// Copy the scanner install/update command to the clipboard (5c guided install).
    public let copyInstallCommand: () -> Void
    /// Open Terminal.app running the ClamAV install command (WP2 fallback).
    public let installInTerminal: () -> Void
    /// Open Terminal.app running the definitions UPDATE (freshclam) — the
    /// stale-definitions fix when ClamAV is already installed.
    public let updateDefinitionsInTerminal: () -> Void
    /// Persist the "Scan drives when they mount" toggle (WP2).
    public let setScanOnMount: (Bool) -> Void
    /// Persist "Notify me when a device looks unsafe" (Wave 2 setter).
    public let setNotifyUnsafe: (Bool) -> Void
    /// Persist "Also when any new device plugs in" (Wave 2 setter).
    public let setNotifyNewDevice: (Bool) -> Void
    public init(openSystemSettings: @escaping (String) -> Void = { _ in },
                activateExtension: @escaping () -> Void = {},
                copyInstallCommand: @escaping () -> Void = {},
                installInTerminal: @escaping () -> Void = {},
                updateDefinitionsInTerminal: @escaping () -> Void = {},
                setScanOnMount: @escaping (Bool) -> Void = { _ in },
                setNotifyUnsafe: @escaping (Bool) -> Void = { _ in },
                setNotifyNewDevice: @escaping (Bool) -> Void = { _ in }) {
        self.openSystemSettings = openSystemSettings
        self.activateExtension = activateExtension
        self.copyInstallCommand = copyInstallCommand
        self.installInTerminal = installInTerminal
        self.updateDefinitionsInTerminal = updateDefinitionsInTerminal
        self.setScanOnMount = setScanOnMount
        self.setNotifyUnsafe = setNotifyUnsafe
        self.setNotifyNewDevice = setNotifyNewDevice
    }
    public static let inert = SettingsActions()
}

public struct SettingsView: View {
    let state: SettingsState
    let actions: SettingsActions
    /// A failed notification-setting write, rendered inline in the
    /// Notifications group (never silent, never a crash).
    let notificationsWriteError: String?
    /// Re-runs the load from the store-error state; nil hides the button.
    let onRetry: (() -> Void)?
    public init(state: SettingsState, actions: SettingsActions = .inert,
                notificationsWriteError: String? = nil,
                onRetry: (() -> Void)? = nil) {
        self.state = state
        self.actions = actions
        self.notificationsWriteError = notificationsWriteError
        self.onRetry = onRetry
    }

    public var body: some View {
        switch state {
        case .loading:
            VStack { ForEach(0..<4, id: \.self) { _ in skeleton } }.padding(PS.s4)
        case .storeError(let msg):
            PSStoreError(message: msg, retry: onRetry)
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
                    group("Notifications") { notificationsSection(l.notifications) }
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

    // MARK: - Permissions

    private func permissionRow(_ r: PermissionRow) -> some View {
        VStack(alignment: .leading, spacing: PS.s2) {
            HStack(alignment: .top, spacing: PS.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.callout.weight(.medium))
                    // The OS permission name, secondary under the purpose-led title (WP2).
                    if let osName = r.osName {
                        Text(osName).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(r.capability).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // A granted row's plain note (e.g. the sensor waits for a
                    // daemon restart). Text only, no fake button.
                    if let note = r.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                statusMark(r.state)
            }
            // Numbered steps + the action button, only while actionable (canon:
            // the button is a guided step, never a dead end).
            if let label = r.state.actionLabel {
                VStack(alignment: .leading, spacing: PS.s1) {
                    ForEach(Array(r.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .top, spacing: PS.s2) {
                            Text("\(idx + 1)").font(.caption2.weight(.semibold))
                                .frame(width: 16, height: 16)
                                .background(Color.primary.opacity(0.08), in: Circle())
                            Text(step).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                // The last activation failure, inline and plain — never swallowed.
                if let error = r.errorLine {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(label) { performAction(r) }.controlSize(.small)
            }
        }
        .frame(minHeight: PS.rowHeight)
    }

    /// The row's right-hand status: icon + word, never colour alone.
    @ViewBuilder private func statusMark(_ s: PermissionRowState) -> some View {
        switch s {
        case .granted:
            HStack(spacing: PS.s1) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Granted").font(.caption)
            }
        case .pending:
            HStack(spacing: PS.s1) {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(.orange)
                Text("Waiting for approval").font(.caption).foregroundStyle(.orange)
            }
        case .missing:
            HStack(spacing: PS.s1) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Not granted").font(.caption).foregroundStyle(.orange)
            }
        case .unavailable:
            HStack(spacing: PS.s1) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Not available").font(.caption).foregroundStyle(.secondary)
            }
        }
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

    // MARK: - Scanner

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
                Text(s.definitionsLine).font(.caption).foregroundStyle(.secondary)
                installCommandRow
            } else {
                HStack(alignment: .top, spacing: PS.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.statusLine).font(.callout)
                        Text(s.definitionsLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: PS.s1) {
                        Image(systemName: s.definitionsStale ? "exclamationmark.triangle" : "checkmark.circle.fill")
                            .foregroundStyle(s.definitionsStale ? .orange : .green)
                        Text(s.definitionsStale ? "Update recommended" : "Ready").font(.caption)
                            .foregroundStyle(s.definitionsStale ? .orange : .primary)
                    }
                }
                // Stale definitions: ClamAV is installed, so the one action is
                // updating the definitions. No raw command on screen; the exact
                // command lives in the button's tooltip and runs in a visible
                // Terminal (never a silent shell-out).
                if s.definitionsStale {
                    Button("Update definitions", action: actions.updateDefinitionsInTerminal)
                        .controlSize(.small)
                        .help("Opens Terminal and runs: \(SettingsViewModel.scannerUpdateCommand)")
                }
            }
            PSToggleRow("Scan drives when they mount", isOn: s.scanOnMount,
                        onToggle: actions.setScanOnMount)
        }
    }

    /// The exact install/update fix, surfaced (05) rather than a dead button: the
    /// command is shown and copyable, plus a Terminal fallback that opens
    /// Terminal.app running it so the user sees it run (WP2).
    private var installCommandRow: some View {
        HStack(spacing: PS.s2) {
            Text(SettingsViewModel.scannerInstallCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, PS.s2).padding(.vertical, PS.s1)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Button("Copy", action: actions.copyInstallCommand).controlSize(.small)
            Button("Install in Terminal", action: actions.installInTerminal).controlSize(.small)
        }
    }

    // MARK: - Notifications

    private func notificationsSection(_ n: NotificationsSection) -> some View {
        VStack(alignment: .leading, spacing: PS.s3) {
            // S1b: the denied state is visible and carries the one recovering
            // action — never a silently broken promise.
            if let hint = n.deniedHint {
                VStack(alignment: .leading, spacing: PS.s2) {
                    Label(hint, systemImage: "bell.slash")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Notification Settings") {
                        actions.openSystemSettings(NotificationsSection.notificationSettingsURL)
                    }
                    .controlSize(.small)
                }
            }
            PSToggleRow("Notify me when a device looks unsafe", isOn: n.notifyUnsafe,
                        onToggle: actions.setNotifyUnsafe)
            PSCheckboxRow("Also when any new device plugs in", isOn: n.notifyNewDevice,
                          onToggle: actions.setNotifyNewDevice)
            // A failed write surfaces inline in plain words (never silence).
            if let error = notificationsWriteError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 30)
    }
}
