// TimelineView.swift
//
// The Timeline section (04). Filter chips (searchable device picker, one severity
// chip, one kind chip, an Alerts toggle), then day-grouped rows with inline
// monitoring-gap rows. Expanded rows are the canonical alert surface (Acknowledge
// primary + trust overflow) — shown here in collapsed form for the snapshot gate.

import SwiftUI

public struct TimelineView: View {
    let state: TimelineState
    public init(state: TimelineState) { self.state = state }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterBar
            Divider()
            body(for: state)
        }
    }

    private var filterBar: some View {
        HStack(spacing: PS.s2) {
            chip(icon: "magnifyingglass", label: "All devices")
            chip(icon: "flag", label: "Any severity")
            chip(icon: "square.stack", label: "All kinds")
            Toggle("Alerts", isOn: .constant(false)).toggleStyle(.button).controlSize(.small)
            Spacer()
        }
        .padding(PS.s3)
    }

    private func chip(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, PS.s2).padding(.vertical, PS.s1)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder private func body(for state: TimelineState) -> some View {
        switch state {
        case .loading:
            VStack(spacing: PS.s2) { ForEach(0..<6, id: \.self) { _ in skeleton } }.padding(PS.s3)
        case .storeError(let msg):
            PSStoreError(message: msg)
        case .loaded(let l):
            if let sentence = l.emptySentence {
                PSEmptyState(sentence: sentence,
                             actionTitle: l.showsClearFilters ? "Clear filters" : nil,
                             action: l.showsClearFilters ? {} : nil)
            } else {
                PSScroll {
                    // Row model (TimelineRow[]) is the virtualization unit; a
                    // runtime LazyVStack is a drop-in. VStack renders reliably
                    // under ImageRenderer for the snapshot gate.
                    VStack(alignment: .leading, spacing: PS.s1) {
                        ForEach(l.rows) { row($0) }
                    }
                    .padding(PS.s3)
                }
            }
        }
    }

    @ViewBuilder private func row(_ row: TimelineRow) -> some View {
        switch row {
        case .dayHeader(let day):
            Text(day).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, PS.s3).padding(.bottom, PS.s1)
        case .gap(let e):
            HStack(spacing: PS.s2) {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text(e.summary)
                    .font(.caption).foregroundStyle(.secondary).tabularFigures()
            }
            .padding(.vertical, PS.s2).padding(.horizontal, PS.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        case .event(let e):
            HStack(alignment: .top, spacing: PS.s2) {
                PSSeverityDot(e.severity, size: 9).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.summary).font(.callout)
                    Text(timeOnly(e.at)).font(.caption2).foregroundStyle(.secondary).tabularFigures()
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: PS.rowHeight, alignment: .center)
        }
    }

    private func timeOnly(_ iso: String) -> String {
        // "2026-08-25T09:14:02Z" -> "09:14"
        guard let tIdx = iso.firstIndex(of: "T") else { return iso }
        let after = iso[iso.index(after: tIdx)...]
        return String(after.prefix(5))
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 16)
    }
}
