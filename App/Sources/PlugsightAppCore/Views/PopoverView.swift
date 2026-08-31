// PopoverView.swift
//
// The popover surface (04): active alerts first, then last five events, then a
// one-line status footer. Open Plugsight is the single primary, top-right. The
// empty sentence renders through the SAME predicate the view model exposes
// (content.emptySentence != nil), so the picture can't lie about data.

import SwiftUI

/// The popover's button wiring. Snapshot rendering passes `.inert` (the default)
/// so the static gallery keeps rendering states without a live shell.
public struct PopoverActions {
    public let openPlugsight: () -> Void
    public let startMonitoring: () -> Void
    public let grant: () -> Void
    public init(openPlugsight: @escaping () -> Void = {},
                startMonitoring: @escaping () -> Void = {},
                grant: @escaping () -> Void = {}) {
        self.openPlugsight = openPlugsight
        self.startMonitoring = startMonitoring
        self.grant = grant
    }
    public static let inert = PopoverActions()
}

public struct PopoverView: View {
    let state: PopoverState
    let actions: PopoverActions
    public init(state: PopoverState, actions: PopoverActions = .inert) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        // Header pinned top, footer pinned bottom, and the middle is the ONLY
        // flexible region — so the view's height is exactly 400, never its content's
        // full (taller) ideal. NSHostingController sized the old fixed-height view to
        // that taller ideal, and the fixed popover then centre-clipped it, eating the
        // "Plugsight" header off the top. A flexible middle removes that possibility.
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            middle
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footerSection
        }
        .frame(width: 340, height: 400)
    }

    private var header: some View {
        HStack {
            Text("Plugsight").font(.headline)
            Spacer()
            if case .stopped = state {
                Button("Start monitoring", action: actions.startMonitoring)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("Open Plugsight", action: actions.openPlugsight).controlSize(.small)
            }
        }
        .padding(PS.s3)
    }

    /// The flexible middle: the only region that scrolls or fills. The footer is
    /// rendered separately (`footerSection`) so it always pins to the bottom.
    @ViewBuilder private var middle: some View {
        switch state {
        case .loading:
            VStack(spacing: PS.s2) {
                ForEach(0..<4, id: \.self) { _ in skeletonRow }
            }.padding(PS.s3)
        case .stopped(let message):
            PSEmptyState(sentence: message, actionTitle: nil, action: nil)
        case .storeError:
            PSStoreError(message: "Can’t read the event record")
        case .content(let c):
            if let sentence = c.emptySentence {
                PSEmptyState(sentence: sentence)
            } else {
                PSScroll {
                    VStack(alignment: .leading, spacing: PS.s2) {
                        if !c.alerts.isEmpty {
                            sectionLabel("Active alerts")
                            ForEach(c.alerts) { alertRow($0) }
                            if c.moreAlertsCount > 0 {
                                Button("and \(c.moreAlertsCount) more") {}
                                    .font(.caption).padding(.horizontal, PS.s3)
                            }
                            Divider().padding(.vertical, PS.s1)
                        }
                        sectionLabel("Recent")
                        ForEach(c.events) { eventRow($0) }
                    }
                    .padding(PS.s3)
                }
            }
        }
    }

    /// The one-line status footer, pinned to the popover's bottom. Present only
    /// when the daemon is up and the store is readable (the `.content` state).
    @ViewBuilder private var footerSection: some View {
        if case .content(let c) = state {
            footerView(c.footer)
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func alertRow(_ a: PopoverAlertRow) -> some View {
        HStack(alignment: .top, spacing: PS.s2) {
            PSSeverityDot(a.severity, size: 10).padding(.top, 4)
            Text(a.summary).font(.callout)
            Spacer()
            Button("Details") {}.controlSize(.small).font(.caption)
        }
    }

    private func eventRow(_ e: PopoverEventRow) -> some View {
        HStack(alignment: .top, spacing: PS.s2) {
            PSSeverityDot(e.severity, size: 8).padding(.top, 4)
            Text(e.summary).font(.callout).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func footerView(_ footer: PopoverFooter) -> some View {
        Divider()
        HStack(spacing: PS.s2) {
            switch footer {
            case .normal(let text):
                Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                Text(text).font(.caption).foregroundStyle(.secondary)
            case .degraded(let grant):
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                Text("\(grant) is off.").font(.caption).foregroundStyle(.secondary)
                Button("Grant", action: actions.grant).font(.caption).controlSize(.small)
            }
            Spacer()
        }
        .padding(PS.s3)
    }

    private var skeletonRow: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.08))
            .frame(height: 14)
    }
}
