// ActivityView.swift
//
// The Activity view (04, S10): the readable event history, reached from the
// quiet link on the Devices home — deliberately NOT a sidebar tab. One real
// control: the "Alerts only" toggle (bound to the view model's filter, which
// threads into the API call). Day-grouped rows in local time with inline
// monitoring-gap rows. Presented as a sheet by the main window.

import SwiftUI

public struct ActivityView: View {
    let state: TimelineState
    /// The one real filter (04): show only ACTIVE alerts.
    let alertsOnly: Bool
    let onToggleAlertsOnly: (Bool) -> Void
    /// Sheet dismissal; nil hides the Done button (previews/snapshots render
    /// the content alone).
    let onClose: (() -> Void)?
    /// Navigate to a row's device (closing the sheet and selecting it in the
    /// Devices home). nil (previews/snapshots) renders plain rows.
    let onOpenDevice: ((String) -> Void)?

    public init(state: TimelineState,
                alertsOnly: Bool = false,
                onToggleAlertsOnly: @escaping (Bool) -> Void = { _ in },
                onClose: (() -> Void)? = nil,
                onOpenDevice: ((String) -> Void)? = nil) {
        self.state = state
        self.alertsOnly = alertsOnly
        self.onToggleAlertsOnly = onToggleAlertsOnly
        self.onClose = onClose
        self.onOpenDevice = onOpenDevice
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: state)
        }
    }

    private var header: some View {
        HStack(spacing: PS.s3) {
            Text("Activity").font(.headline)
            Spacer()
            // Hand-drawn checkbox (like PSToggleRow) so it renders faithfully
            // under ImageRenderer; it is a real, working toggle.
            Button {
                onToggleAlertsOnly(!alertsOnly)
            } label: {
                HStack(spacing: PS.s1) {
                    Image(systemName: alertsOnly ? "checkmark.square.fill" : "square")
                        .foregroundStyle(alertsOnly ? Color.accentColor : Color.secondary)
                    Text("Alerts only").font(.caption)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(alertsOnly ? [.isSelected] : [])
            .accessibilityLabel("Alerts only")
            if let onClose {
                // Quiet bordered close: dismissing a sheet is not the most
                // important action in the product, so it carries no accent.
                Button("Done") { onClose() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(PS.s3)
    }

    @ViewBuilder private func body(for state: TimelineState) -> some View {
        switch state {
        case .loading:
            VStack(spacing: PS.s2) { ForEach(0..<6, id: \.self) { _ in skeleton } }.padding(PS.s3)
                .frame(maxHeight: .infinity, alignment: .top)
        case .storeError(let msg):
            PSStoreError(message: msg)
        case .loaded(let l):
            if let sentence = l.emptySentence {
                // The alerts-only empty names its filter and carries the one
                // recovering action inline (no dead ends).
                if l.alertsOnly {
                    PSEmptyState(sentence: sentence,
                                 actionTitle: "Show everything",
                                 action: { onToggleAlertsOnly(false) })
                } else {
                    PSEmptyState(sentence: sentence)
                }
            } else {
                PSScroll {
                    // LazyVStack at runtime (the row model is the virtualization
                    // unit); ImageRenderer does not lay out lazy stacks, so the
                    // snapshot gate renders the plain column.
                    if PSRender.snapshotMode {
                        VStack(alignment: .leading, spacing: PS.s1) {
                            ForEach(l.rows) { row($0) }
                        }
                        .padding(PS.s3)
                    } else {
                        LazyVStack(alignment: .leading, spacing: PS.s1) {
                            ForEach(l.rows) { row($0) }
                        }
                        .padding(PS.s3)
                    }
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
                // Local wall-clock window from the structured detail; the raw
                // summary (UTC ISO stamps) only when the detail is missing.
                Text(GapVocabulary.displaySummary(e))
                    .font(.caption).foregroundStyle(.secondary).tabularFigures()
            }
            .padding(.vertical, PS.s2).padding(.horizontal, PS.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        case .event(let e):
            // A row about a device navigates to that device (closing the
            // sheet); rows without one stay plain text.
            if let deviceId = e.deviceId, let onOpenDevice {
                Button {
                    onOpenDevice(deviceId)
                } label: {
                    eventRowBody(e, navigable: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this device")
            } else {
                eventRowBody(e, navigable: false)
            }
        }
    }

    private func eventRowBody(_ e: EventDTO, navigable: Bool) -> some View {
        HStack(alignment: .top, spacing: PS.s2) {
            PSSeverityDot(e.severity, size: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.summary).font(.callout)
                Text(timeOnly(e.at)).font(.caption2).foregroundStyle(.secondary).tabularFigures()
            }
            Spacer(minLength: 0)
            if navigable {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: PS.rowHeight, alignment: .center)
    }

    private func timeOnly(_ iso: String) -> String {
        // Parsed + rendered in the viewer's local timezone (shared formatter),
        // never sliced out of the UTC wire string.
        TimeFormatting.timeOnly(iso)
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 16)
    }
}
