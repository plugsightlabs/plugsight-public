// PopoverView.swift
//
// The popover surface (04): a machine verdict line in the title row, active
// alerts (each with a working Details route), the last five events with local
// times, then a one-line status footer and the Open Plugsight action. The empty
// sentence renders through the SAME predicate the view model exposes
// (content.emptySentence != nil), so the picture can't lie about data.
//
// Sizing: width is fixed at 340; height follows content between 200 and 480.
// The hosting controller (AppDelegate) reads the fitting size via
// sizingOptions, so an empty popover is short and a busy one grows to the max
// and then scrolls. No fixed height, no centre-clip.

import SwiftUI

/// The popover's button wiring. Snapshot rendering passes `.inert` (the default)
/// so the static gallery keeps rendering states without a live shell.
public struct PopoverActions {
    public let openPlugsight: () -> Void
    public let startMonitoring: () -> Void
    public let grant: () -> Void
    /// Details on an alert row: front the main window on this alert's device.
    public let openDevice: (String) -> Void
    /// The store-error "Reopen": re-run the load so the record is reopened.
    public let reload: () -> Void
    public init(openPlugsight: @escaping () -> Void = {},
                startMonitoring: @escaping () -> Void = {},
                grant: @escaping () -> Void = {},
                openDevice: @escaping (String) -> Void = { _ in },
                reload: @escaping () -> Void = {}) {
        self.openPlugsight = openPlugsight
        self.startMonitoring = startMonitoring
        self.grant = grant
        self.openDevice = openDevice
        self.reload = reload
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
        // Header top, footer bottom, and the middle is the only region that
        // scrolls. The view's ideal height is its content height; the frame
        // below clamps it to 200...480 and the hosting controller sizes the
        // popover to that fitting height (top-aligned, never centre-clipped).
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            middle
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            footerSection
        }
        .frame(width: 340)
        .frame(minHeight: 200, maxHeight: 480)
    }

    private var header: some View {
        HStack(spacing: PS.s2) {
            Text("Plugsight").font(.headline)
            Spacer()
            if case .content(let c) = state {
                verdictLine(c.verdict)
            }
            if case .stopped = state {
                Button("Start monitoring", action: actions.startMonitoring)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(PS.s3)
    }

    /// The machine verdict: SafetyBadge's icon + the plain verdict words, one
    /// visual answer to "am I okay?" (icon + word, never colour alone).
    private func verdictLine(_ verdict: PopoverVerdict) -> some View {
        VerdictBadge(verdict: verdict)
    }

    /// The middle region: alerts + recent events, scrolling when tall.
    @ViewBuilder private var middle: some View {
        switch state {
        case .loading:
            VStack(spacing: PS.s2) {
                ForEach(0..<4, id: \.self) { _ in skeletonRow }
            }.padding(PS.s3)
        case .stopped(let message):
            // Title + supporting line; the recovery is the Start monitoring
            // button in the header right above this text.
            VStack(spacing: PS.s2) {
                Text(PopoverViewModel.stoppedTitle)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(PS.s5)
        case .storeError(let message):
            // Local error block (not PSStoreError): the Reopen button here is
            // wired to a real reload, never painted.
            PopoverErrorView(message: message, onReopen: actions.reload)
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
                                Button("and \(c.moreAlertsCount) more", action: actions.openPlugsight)
                                    .font(.caption)
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

    /// The one-line status footer + the Open Plugsight action, pinned to the
    /// popover's bottom. Present only when the daemon is up and the store is
    /// readable (the `.content` state).
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
            VStack(alignment: .leading, spacing: 2) {
                Text(a.summary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(a.time).font(.caption).foregroundStyle(.secondary).tabularFigures()
            }
            Spacer()
            Button("Details") {
                if let id = a.deviceId { actions.openDevice(id) } else { actions.openPlugsight() }
            }
            .controlSize(.small).font(.caption)
        }
    }

    private func eventRow(_ e: PopoverEventRow) -> some View {
        HStack(alignment: .top, spacing: PS.s2) {
            Text(e.time).font(.caption).foregroundStyle(.secondary).tabularFigures()
                .frame(width: 56, alignment: .leading).padding(.top, 1)
            PSSeverityDot(e.severity, size: 8).padding(.top, 4)
            Text(e.summary).font(.callout).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func footerView(_ footer: PopoverFooter) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: PS.s2) {
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
            Button(action: actions.openPlugsight) {
                Text("Open Plugsight").frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
        }
        .padding(PS.s3)
    }

    private var skeletonRow: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.08))
            .frame(height: 14)
    }
}

/// The verdict badge: SafetyBadge's silhouette + tint with the popover's verdict
/// words ("All devices safe" / "N need attention"). Icon + word, and the word is
/// the VoiceOver label too.
private struct VerdictBadge: View {
    let verdict: PopoverVerdict
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let status = verdict.safetyStatus
        // De-neon: only the icon carries the verdict tint; the word stays in
        // the primary label colour (still icon + word, never colour alone).
        HStack(spacing: PS.s1) {
            Image(systemName: PS.safetySymbol(forStatus: status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PS.safetyColor(forStatus: status, dark: scheme == .dark))
            Text(verdict.word).font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(verdict.word)
    }
}

/// The popover's store-error block: what, why, one WORKING action. Local to the
/// popover because the shared PSStoreError renders a placeholder button; here
/// Reopen actually re-runs the load.
struct PopoverErrorView: View {
    let message: String
    let onReopen: () -> Void
    var body: some View {
        VStack(spacing: PS.s3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message).font(.callout).multilineTextAlignment(.center)
            Text("The event record couldn't be read. Reopening usually fixes it.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Reopen", action: onReopen)
        }
        .frame(maxWidth: .infinity)
        .padding(PS.s5)
    }
}
