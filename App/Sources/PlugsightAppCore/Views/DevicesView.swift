// DevicesView.swift
//
// The Devices section (04). Present devices lead, sorted by last activity; a
// searchable field appears past ten; historical collapse below. Rows are 44pt.
// A quiet behavior tier word shows only at notice+ — all-clear devices carry no
// chip and no colour (data honesty). Empty is deliberately action-free.

import SwiftUI
import PlugsightCore

public struct DevicesView: View {
    let state: DevicesState
    // Selection seam. Defaults keep the snapshot/preview path (state-only) intact;
    // the live host passes onSelect so a tapped row drives the inspector pane, and
    // selectedId so the current row reads as selected.
    let selectedId: String?
    let onSelect: (String) -> Void
    public init(state: DevicesState,
                selectedId: String? = nil,
                onSelect: @escaping (String) -> Void = { _ in }) {
        self.state = state; self.selectedId = selectedId; self.onSelect = onSelect
    }

    public var body: some View {
        switch state {
        case .loading:
            VStack(spacing: PS.s2) { ForEach(0..<6, id: \.self) { _ in skeleton } }.padding(PS.s3)
        case .storeError(let msg):
            PSStoreError(message: msg)
        case .loaded(let l):
            if let sentence = l.emptySentence {
                PSEmptyState(sentence: sentence)
            } else {
                PSScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        if l.showsSearch {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                Text("Search \(l.present.count) devices").foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(PS.s2)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.bottom, PS.s2)
                        }
                        ForEach(l.present) { deviceRow($0) }
                        if !l.historical.isEmpty {
                            DisclosureGroup {
                                ForEach(l.historical) { deviceRow($0) }
                            } label: {
                                Text("Historical (\(l.historical.count))")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.top, PS.s3)
                        }
                    }
                    .padding(PS.s3)
                }
            }
        }
    }

    private func deviceRow(_ d: DeviceRow) -> some View {
        let selected = d.deviceId == selectedId
        return Button { onSelect(d.deviceId) } label: {
            HStack(spacing: PS.s3) {
                Image(systemName: icon(for: d.roles))
                    .foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.callout)
                    Text(d.roles.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if d.scanning {
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                }
                if let chip = d.behaviorChipWord {
                    PSBehaviorChip(chip)
                }
                if d.trustLabel != "Default" {
                    PSChip(d.trustLabel, tint: trustTint(d.trustLabel))
                }
            }
            .padding(.horizontal, PS.s2)
            .frame(minHeight: PS.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func icon(for roles: [String]) -> String {
        if roles.contains("keyboard") { return "keyboard" }
        if roles.contains("mouse") { return "computermouse" }
        if roles.contains("storage") { return "externaldrive" }
        if roles.contains("camera") { return "camera" }
        return "cable.connector"
    }

    private func trustTint(_ label: String) -> Color {
        switch label {
        case "Trusted": return .green
        case "Flagged": return .orange
        default: return .secondary
        }
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 40)
    }
}
