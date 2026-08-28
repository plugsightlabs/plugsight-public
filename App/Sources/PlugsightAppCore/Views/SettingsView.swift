// SettingsView.swift
//
// The Settings section (04): three groups, each row self-legible, no global save.
// The disabled "Hold new drives until scanned" toggle shows its reason as inline
// text, never hover-only (8b). Definitions age renders "unknown" as its own muted
// state. The threshold picker's options describe themselves.

import SwiftUI

public struct SettingsView: View {
    let state: SettingsState
    public init(state: SettingsState) { self.state = state }

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
                Text(r.capability).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .missing(let action) = r.state {
                Button(action) {}.controlSize(.small)
            }
        }
        .frame(minHeight: PS.rowHeight)
    }

    private func scannerSection(_ s: ScannerSection) -> some View {
        VStack(alignment: .leading, spacing: PS.s3) {
            if s.showsGuidedInstall {
                Label("No scanner found. Install one to scan drives on mount.",
                      systemImage: "arrow.down.circle")
                    .font(.callout)
                Button("Install scanner") {}.controlSize(.small)
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
            PSToggleRow("Scan drives when they mount", isOn: s.scanOnMount)
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
        if case .granted = s { return "checkmark.circle.fill" }
        return "exclamationmark.circle"
    }
    private func colorFor(_ s: PermissionRowState) -> Color {
        if case .granted = s { return .green }
        return .orange
    }
    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 30)
    }
}
