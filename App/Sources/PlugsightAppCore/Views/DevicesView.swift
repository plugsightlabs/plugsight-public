// DevicesView.swift
//
// The Devices home (04, Direction C "verdict header"): a machine-level verdict
// band up top, then a dense table — role icon, name (+roles), safety badge,
// last scan, last check, a quiet alert-count chip. A REAL search field filters
// by name/roles past ten devices; historical devices collapse below; a quiet
// Activity link sits bottom-left. Row selection drives the inspector pane.

import SwiftUI
import PlugsightCore

public struct DevicesView: View {
    let state: DevicesState
    // Selection seam. Defaults keep the snapshot/preview path (state-only) intact;
    // the live host passes onSelect so a tapped row drives the inspector pane, and
    // selectedId so the current row reads as selected.
    let selectedId: String?
    let onSelect: (String) -> Void
    /// Opens the Activity view (S10a); nil hides the link (previews).
    let onOpenActivity: (() -> Void)?
    /// Re-runs the load from the store-error state; nil hides the button.
    let onRetry: (() -> Void)?
    @State private var searchText = ""

    public init(state: DevicesState,
                selectedId: String? = nil,
                onSelect: @escaping (String) -> Void = { _ in },
                onOpenActivity: (() -> Void)? = nil,
                onRetry: (() -> Void)? = nil) {
        self.state = state; self.selectedId = selectedId
        self.onSelect = onSelect; self.onOpenActivity = onOpenActivity
        self.onRetry = onRetry
    }

    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        switch state {
        case .loading:
            VStack(spacing: PS.s2) { ForEach(0..<6, id: \.self) { _ in skeleton } }.padding(PS.s3)
        case .storeError(let msg):
            PSStoreError(message: msg, retry: onRetry)
        case .loaded(let l):
            if let sentence = l.emptySentence {
                emptyBody(sentence)
            } else {
                loadedBody(l)
            }
        }
    }

    /// The empty home still says what the app is doing: a standard header line
    /// (monitoring is on) above the empty sentence, and the Activity link stays
    /// reachable. No content-free void.
    private func emptyBody(_ sentence: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: PS.s3) {
                HStack(alignment: .center, spacing: PS.s3) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitoring is on").font(.callout.weight(.semibold))
                        Text(sentence).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, PS.s4).padding(.vertical, PS.s3)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                Text("New devices appear here the moment they plug in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(PS.s3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if onOpenActivity != nil {
                Divider()
                activityLink
            }
        }
    }

    private func loadedBody(_ l: DevicesLoaded) -> some View {
        let filtered = l.filtered(query: searchText)
        return VStack(alignment: .leading, spacing: 0) {
            PSScroll {
                VStack(alignment: .leading, spacing: 0) {
                    if let verdict = l.verdict {
                        verdictBand(verdict).padding(.bottom, PS.s3)
                    }
                    if l.showsSearch {
                        searchField(count: l.present.count).padding(.bottom, PS.s2)
                    }
                    table(filtered)
                    if filtered.present.isEmpty && filtered.historical.isEmpty
                        && !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No devices match \u{201C}\(searchText)\u{201D}")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, PS.s4)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(PS.s3)
            }
            if onOpenActivity != nil {
                Divider()
                activityLink
            }
        }
    }

    // MARK: - Verdict band (Direction C)

    /// De-neon (owner feedback): a NEUTRAL card — plain background, hairline
    /// border — with a small tinted status icon and primary-colour text. The
    /// DetailSafe artboard's calm look is the reference; only the icon carries
    /// the verdict tint.
    private func verdictBand(_ v: FleetVerdict) -> some View {
        let tint = PS.safetyColor(forStatus: v.status, dark: scheme == .dark)
        return HStack(alignment: .center, spacing: PS.s3) {
            Image(systemName: PS.safetySymbol(forStatus: v.status))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.headline).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                if let detail = v.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PS.s4).padding(.vertical, PS.s3)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Search (real: filters the rows below)

    private func searchField(count: Int) -> some View {
        HStack(spacing: PS.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            if PSRender.snapshotMode {
                // ImageRenderer draws an AppKit placeholder for TextField; the
                // snapshot shows the field's resting face. The live app gets
                // the real, filtering TextField below.
                Text("Search \(count) devices").foregroundStyle(.secondary)
                Spacer()
            } else {
                TextField("Search \(count) devices", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
        }
        .padding(PS.s2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Table

    // Column geometry. The metric columns are fixed; the name column is the
    // one flexible column and has a REAL minimum so it can never collapse to
    // zero width (live-walk defect: rows rendered with no name and the header
    // wrapped to "De-vice"). paneMinWidth is the exact sum of the columns,
    // spacings and paddings; the window host must give the pane at least that.
    static let nameMinWidth: CGFloat = 180
    private var nameMinWidth: CGFloat { Self.nameMinWidth }
    private let statusWidth: CGFloat = 118
    private let scanWidth: CGFloat = 140
    private let checkWidth: CGFloat = 110
    private let alertsWidth: CGFloat = 28

    /// The pane's honest minimum width: name(180) + 4 gaps(12) + status(118)
    /// + scan(140) + check(110) + alerts(28) + row padding(16) + pane padding(24).
    public static let paneMinWidth: CGFloat = 664

    private func table(_ l: DevicesLoaded) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeader
            Divider()
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
    }

    private var tableHeader: some View {
        HStack(spacing: PS.s3) {
            Text("Device").lineLimit(1)
                .frame(minWidth: nameMinWidth, maxWidth: .infinity, alignment: .leading)
            Text("Status").lineLimit(1).frame(width: statusWidth, alignment: .leading)
            Text("Last scan").lineLimit(1).frame(width: scanWidth, alignment: .leading)
            Text("Last check").lineLimit(1).frame(width: checkWidth, alignment: .leading)
            Spacer().frame(width: alertsWidth)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, PS.s2).padding(.vertical, PS.s1)
    }

    private func deviceRow(_ d: DeviceRow) -> some View {
        let selected = d.deviceId == selectedId
        return Button { onSelect(d.deviceId) } label: {
            HStack(spacing: PS.s3) {
                HStack(spacing: PS.s2) {
                    Image(systemName: icon(for: d.roles))
                        .foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.callout).lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: PS.s2) {
                            Text(d.roles.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if d.trustLabel != "Default" {
                                PSChip(d.trustLabel, tint: PS.trustTint(d.trustTier))
                            }
                            if let chip = d.behaviorChipWord {
                                PSBehaviorChip(chip)
                            }
                        }
                    }
                }
                .frame(minWidth: nameMinWidth, maxWidth: .infinity, alignment: .leading)
                PSSafetyBadge(d.safetyStatus, compact: true)
                    .frame(width: statusWidth, alignment: .leading)
                Text(d.lastScanText)
                    .font(.caption).foregroundStyle(.secondary).tabularFigures()
                    .lineLimit(1)
                    .frame(width: scanWidth, alignment: .leading)
                Text(d.lastCheckText)
                    .font(.caption).foregroundStyle(.secondary).tabularFigures()
                    .lineLimit(1)
                    .frame(width: checkWidth, alignment: .leading)
                Group {
                    if d.activeAlerts > 0 {
                        Text("\(d.activeAlerts)")
                            .font(.caption2.weight(.semibold)).tabularFigures()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                            .accessibilityLabel("\(d.activeAlerts) active alerts")
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: alertsWidth, alignment: .center)
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

    // MARK: - Activity link (S10a: quiet, bottom-left, not a tab)

    private var activityLink: some View {
        HStack {
            Button {
                onOpenActivity?()
            } label: {
                Label("Activity", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Event history, including monitoring gaps.")
            Spacer()
        }
        .padding(.horizontal, PS.s3).padding(.vertical, PS.s2)
    }

    private func icon(for roles: [String]) -> String {
        if roles.contains("keyboard") { return "keyboard" }
        if roles.contains("mouse") { return "computermouse" }
        if roles.contains("storage") { return "externaldrive" }
        if roles.contains("camera") { return "camera" }
        return "cable.connector"
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 40)
    }
}
