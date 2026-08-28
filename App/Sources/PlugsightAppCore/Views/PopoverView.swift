// PopoverView.swift
//
// The popover surface (04): active alerts first, then last five events, then a
// one-line status footer. Open Plugsight is the single primary, top-right. The
// empty sentence renders through the SAME predicate the view model exposes
// (content.emptySentence != nil), so the picture can't lie about data.

import SwiftUI

public struct PopoverView: View {
    let state: PopoverState
    public init(state: PopoverState) { self.state = state }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 340, height: 400)
    }

    private var header: some View {
        HStack {
            Text("Plugsight").font(.headline)
            Spacer()
            if case .stopped = state {
                Button("Start monitoring") {}.buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("Open Plugsight") {}.controlSize(.small)
            }
        }
        .padding(PS.s3)
    }

    @ViewBuilder private var content: some View {
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
                VStack {
                    PSEmptyState(sentence: sentence)
                    footerView(c.footer)
                }
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
                footerView(c.footer)
            }
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
                Button("Grant") {}.font(.caption).controlSize(.small)
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
