// DeviceInspectorView.swift
//
// The device inspector pane (04, DetailSafe/DetailUnsafe artboards). Verdict
// first: the safety badge headline plus each reason as a plain sentence with
// its ONE working action (scan, quarantine restore, alert acknowledge, the
// Input Monitoring deep link, or plain advice). The Behavior card sits below
// the verdict; trust collapses into the "Alerts from this device" disclosure;
// scan records cap at five with Show all, and a storage device with no scans
// says "Not scanned yet" with a working Scan now instead of hiding the section.

import SwiftUI
import PlugsightCore

public struct DeviceInspectorView: View {
    let state: InspectorState
    // Interaction seams. Defaults keep the snapshot/preview path (state-only)
    // intact; the live host (InspectorHost) passes the view model's callbacks
    // and published error state so every rendered control performs its action.
    let undoToast: UndoToast?
    let trustWriteError: String?
    let actionError: String?
    let onSetTrust: (TrustTier) -> Void
    let onUndo: () -> Void
    let onDismissUndo: () -> Void
    let onDismissError: () -> Void
    let onDismissActionError: () -> Void
    let onScanNow: () -> Void
    let onCancelScan: (String) -> Void
    let onRestoreQuarantine: (String) -> Void
    let onAcknowledgeAlert: (String) -> Void
    let onOpenInputMonitoring: () -> Void
    /// Re-runs the load from the notFound/storeError state (no dead ends: the
    /// pane must never strand the user on an error without a way back).
    let onRetry: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    /// The quarantine row awaiting the explicit restore confirmation.
    @State private var pendingRestoreId: String?
    /// Whether the scans list shows all rows or the first five.
    @State private var showAllScans = false

    public init(state: InspectorState,
                undoToast: UndoToast? = nil,
                trustWriteError: String? = nil,
                actionError: String? = nil,
                onSetTrust: @escaping (TrustTier) -> Void = { _ in },
                onUndo: @escaping () -> Void = {},
                onDismissUndo: @escaping () -> Void = {},
                onDismissError: @escaping () -> Void = {},
                onDismissActionError: @escaping () -> Void = {},
                onScanNow: @escaping () -> Void = {},
                onCancelScan: @escaping (String) -> Void = { _ in },
                onRestoreQuarantine: @escaping (String) -> Void = { _ in },
                onAcknowledgeAlert: @escaping (String) -> Void = { _ in },
                onOpenInputMonitoring: @escaping () -> Void = {},
                onRetry: (() -> Void)? = nil) {
        self.state = state
        self.undoToast = undoToast
        self.trustWriteError = trustWriteError
        self.actionError = actionError
        self.onSetTrust = onSetTrust
        self.onUndo = onUndo
        self.onDismissUndo = onDismissUndo
        self.onDismissError = onDismissError
        self.onDismissActionError = onDismissActionError
        self.onScanNow = onScanNow
        self.onCancelScan = onCancelScan
        self.onRestoreQuarantine = onRestoreQuarantine
        self.onAcknowledgeAlert = onAcknowledgeAlert
        self.onOpenInputMonitoring = onOpenInputMonitoring
        self.onRetry = onRetry
    }

    /// The daemon emits signal verdicts "normal" / "suspicious"
    /// (DaemonCore.signalsJSON); older canned fixtures used "clear". Both read
    /// as the clear/green case; anything else renders as a caution.
    public static func verdictIsClear(_ verdict: String) -> Bool {
        verdict == "normal" || verdict == "clear"
    }

    /// The scans list caps at five rows before the Show all expander (04).
    public static let scansCap = 5

    public var body: some View {
        switch state {
        case .loading:
            VStack(spacing: PS.s3) { ForEach(0..<3, id: \.self) { _ in card { skeleton } } }.padding(PS.s4)
        case .notFound(let msg), .storeError(let msg):
            PSStoreError(message: msg, retry: onRetry)
        case .loaded(let l):
            ZStack(alignment: .bottom) {
                PSScroll {
                    VStack(alignment: .leading, spacing: PS.s4) {
                        identityHeader(l.header)
                        verdictSection(l)
                        if let error = actionError {
                            errorBanner(error, dismiss: onDismissActionError)
                        }
                        // The Behavior (typing) card renders only for devices
                        // with a keyboard/HID input face, or when the daemon
                        // actually scored typing; a camera or hub shows nothing
                        // (no irrelevant "no typing observed" fields).
                        if l.header.hasInputFace || l.behavior.showsNumber {
                            behaviorCard(l.behavior)
                        }
                        alertsFromDeviceDisclosure(l.trust)
                        scansSection(l)
                    }
                    .padding(PS.s4)
                }
                if let toast = undoToast {
                    undoToastView(toast)
                }
            }
        }
    }

    // MARK: - Verdict (leads the pane)

    private func verdictSection(_ l: InspectorLoaded) -> some View {
        VStack(alignment: .leading, spacing: PS.s3) {
            PSSafetyBadge(l.verdict.status)
            if l.verdict.reasons.isEmpty && l.verdict.status == "grey" {
                // Honest grey copy: "never checked" may only be claimed when the
                // scan history is empty too; a failed-only history says why.
                Text(l.scans.isEmpty
                     ? "This device has not been checked yet."
                     : "The last scan did not finish, so there is no verdict yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // The safe verdict says WHEN (DetailSafe artboard): the last clean
            // scan's local time for drives; the continuous-check line otherwise.
            if l.verdict.reasons.isEmpty && l.verdict.status == "green" {
                if l.header.isStorage, let clean = l.lastCleanScan,
                   let finished = clean.finishedAtDisplay {
                    Text("Scanned and safe. Last scan \(finished), nothing found.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if l.header.present {
                    Text("Safe. Checked continuously while connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(l.verdict.reasons) { reason in
                VStack(alignment: .leading, spacing: PS.s2) {
                    Text(reason.sentence).font(.callout)
                    reasonAction(reason, loaded: l)
                }
            }
        }
        .padding(PS.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// One reason's ONE action: a working button, an inline list, or advice.
    @ViewBuilder private func reasonAction(_ reason: SafetyReasonVM, loaded: InspectorLoaded) -> some View {
        switch reason.action {
        case .scanAgain:
            Button("Scan again") { onScanNow() }.controlSize(.small)
        case .grantInputMonitoring:
            Button("Turn on Input Monitoring") { onOpenInputMonitoring() }.controlSize(.small)
        case .reviewQuarantine:
            quarantineList(loaded.quarantineRows)
        case .reviewAlerts:
            alertsList(loaded.alerts)
        case .installScanner, .unplug, .none, .other:
            if let advice = reason.action.adviceText {
                Text(advice).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Quarantined files (DetailUnsafe artboard): "Keep quarantined" leads as
    /// the recommended safe state, Restore is a guarded SECONDARY action behind
    /// the existing two-step confirm, "Scan again" stays reachable, and the
    /// safe-to-unplug advice closes the block. Restore is never the lone button.
    @ViewBuilder private func quarantineList(_ rows: [QuarantineRecordDTO]) -> some View {
        if rows.isEmpty {
            Text("The quarantined file was already handled.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: PS.s2) {
                ForEach(rows, id: \.quarantineId) { q in
                    VStack(alignment: .leading, spacing: PS.s1) {
                        HStack(spacing: PS.s2) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .font(.caption).foregroundStyle(.red)
                            Text(q.filePath).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: PS.s2)
                        }
                        Text(q.signature).font(.caption2).foregroundStyle(.secondary)
                        HStack(spacing: PS.s2) {
                            // The recommended action leads and reads as the
                            // current safe state; pressing it cancels a pending
                            // restore (and otherwise affirms the default).
                            Button {
                                pendingRestoreId = nil
                            } label: {
                                Label("Keep quarantined", systemImage: "checkmark")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small).font(.caption)
                            if pendingRestoreId != q.quarantineId {
                                Button("Restore") { pendingRestoreId = q.quarantineId }
                                    .controlSize(.small).font(.caption)
                            }
                        }
                        if pendingRestoreId == q.quarantineId {
                            HStack(spacing: PS.s2) {
                                Text("This restores a file the scanner flagged. Only do this for a false positive.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Button("Restore anyway") {
                                    pendingRestoreId = nil
                                    onRestoreQuarantine(q.quarantineId)
                                }
                                .controlSize(.small).font(.caption2)
                            }
                        }
                    }
                    .padding(PS.s2)
                    .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                Text("Safe to unplug. The infected file cannot run from quarantine.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Scan again") { onScanNow() }.controlSize(.small).font(.caption)
            }
        }
    }

    /// This device's active alerts with a working Acknowledge each.
    @ViewBuilder private func alertsList(_ alerts: [AlertDTO]) -> some View {
        if alerts.isEmpty {
            Text("The alert was already handled.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: PS.s2) {
                ForEach(alerts, id: \.alertId) { a in
                    VStack(alignment: .leading, spacing: PS.s1) {
                        HStack(alignment: .top, spacing: PS.s2) {
                            PSSeverityDot(a.severity, size: 9).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.summary).font(.caption)
                                Text(a.why).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: PS.s2)
                            Button("Acknowledge") { onAcknowledgeAlert(a.alertId) }
                                .controlSize(.small).font(.caption)
                        }
                    }
                    .padding(PS.s2)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    /// The shared inline error shape (what + Dismiss), same as the trust error.
    private func errorBanner(_ error: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PS.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
            Text(error).font(.caption).foregroundStyle(.primary)
            Spacer(minLength: PS.s2)
            Button("Dismiss") { dismiss() }.controlSize(.small).font(.caption2)
        }
        .padding(PS.s2)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    /// The undo toast raised after a trust change: what happened + an Undo.
    private func undoToastView(_ toast: UndoToast) -> some View {
        HStack(spacing: PS.s3) {
            Text(toast.message).font(.caption)
            Spacer(minLength: PS.s3)
            Button("Undo") { onUndo() }.controlSize(.small).font(.caption.weight(.semibold))
            Button {
                onDismissUndo()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, PS.s3).padding(.vertical, PS.s2)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .padding(PS.s3)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PS.s3) { content() }
            .padding(PS.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func identityHeader(_ h: InspectorHeader) -> some View {
        card {
            VStack(alignment: .leading, spacing: PS.s1) {
                Text(h.name).font(.title3.weight(.semibold))
                Text(h.rolesText).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: PS.s3) {
                // Labeled, never a bare hex pair: the codes get a caption so a
                // reader knows what "04e8:20d3" is without hovering.
                Text("USB ID \(h.vidPid)").font(.caption).foregroundStyle(.secondary).tabularFigures()
                    // Real tooltip: the raw USB identity codes for the curious.
                    .help("USB vendor and product ID (VID:PID).")
                if let serial = h.serial {
                    Text("Serial \(serial)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let absent = h.absentNote {
                Label(absent, systemImage: "bolt.horizontal.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func behaviorCard(_ b: BehaviorCardState) -> some View {
        card {
            Text(BehaviorVocabulary.label.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            switch b {
            case .loading:
                skeleton
            case .score(let value, let tierWord, let signals, let caveat):
                HStack(alignment: .firstTextBaseline, spacing: PS.s2) {
                    Text("\(value)").font(.system(size: 34, weight: .semibold)).tabularFigures()
                    Text(tierWord).font(.headline)
                        .foregroundStyle(tierWord == "high" ? .orange : .primary)
                }
                // Real tooltip: the meaning line lives here, not as permanent prose.
                .help(BehaviorVocabulary.meaning)
                DisclosureGroup("How this was scored") {
                    VStack(alignment: .leading, spacing: PS.s2) {
                        Text(BehaviorVocabulary.meaning).font(.caption).foregroundStyle(.secondary)
                        ForEach(signals, id: \.id) { s in
                            HStack {
                                Text(RoleNaming.plain(s.id.replacingOccurrences(of: "_", with: " ")))
                                    .font(.caption)
                                Spacer()
                                Text(s.observed).font(.caption).foregroundStyle(.secondary)
                                Text(s.verdict).font(.caption2)
                                    .foregroundStyle(Self.verdictIsClear(s.verdict) ? .green : .orange)
                            }
                        }
                        Text(caveat).font(.caption2).italic().foregroundStyle(.secondary)
                    }
                    .padding(.top, PS.s1)
                }
                .font(.caption)
            case .sensorOff(let msg):
                Label(msg, systemImage: "keyboard.badge.ellipsis")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Turn on Input Monitoring") { onOpenInputMonitoring() }
                    .controlSize(.small).font(.caption)
            case .noData(let msg):
                Text(msg).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Trust, collapsed behind "Alerts from this device" (04): the working
    /// segmented control plus the selected tier's plain consequence caption.
    private func alertsFromDeviceDisclosure(_ t: TrustControlVM) -> some View {
        card {
            DisclosureGroup("Alerts from this device") {
                VStack(alignment: .leading, spacing: PS.s3) {
                    PSSegmentedControl(segments: t.segments.map { ($0.tier, $0.label) },
                                       current: t.current, onSelect: onSetTrust)
                    if let seg = t.segments.first(where: { $0.tier == t.current }) {
                        Text(seg.consequence).font(.caption).foregroundStyle(.secondary)
                    }
                    // A failed trust write never destroys the selection: the reason
                    // renders inline here, next to the control, with a dismiss.
                    if let error = trustWriteError {
                        errorBanner(error, dismiss: onDismissError)
                            .accessibilityLabel("Trust not saved: \(error)")
                    }
                    if t.showForgeabilityNote {
                        Label(TrustVocabulary.firstUseForgeabilityNote, systemImage: "info.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(PS.s2)
                            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.top, PS.s2)
            }
            .font(.callout)
        }
    }

    // MARK: - Scans

    /// The scans area: always present for a storage device (an empty list
    /// explains itself with a working Scan now); non-storage devices with no
    /// scan history show nothing.
    @ViewBuilder private func scansSection(_ l: InspectorLoaded) -> some View {
        if l.header.isStorage || !l.scans.isEmpty {
            card {
                Text("SCANS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if l.scans.isEmpty {
                    HStack(spacing: PS.s3) {
                        Text("Not scanned yet").font(.callout).foregroundStyle(.secondary)
                        Button("Scan now") { onScanNow() }.controlSize(.small).font(.caption)
                    }
                } else {
                    let visible = showAllScans ? l.scans : Array(l.scans.prefix(Self.scansCap))
                    ForEach(visible) { scanRow($0) }
                    if l.scans.count > Self.scansCap && !showAllScans {
                        Button("Show all (\(l.scans.count))") { showAllScans = true }
                            .controlSize(.small).font(.caption)
                    }
                }
            }
        }
    }

    private func scanRow(_ s: ScanRecordVM) -> some View {
        VStack(alignment: .leading, spacing: PS.s1) {
            HStack {
                // De-neon: tinted icon + primary-colour word (never tinted text,
                // never colour alone).
                Image(systemName: symbol(for: s.state))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color(for: s.state))
                Text(s.stateWord).font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                if let p = s.progress {
                    Text("\(Int(p * 100))%").font(.caption).tabularFigures().foregroundStyle(.secondary)
                }
                Text(s.startedAtDisplay).font(.caption).foregroundStyle(.secondary).tabularFigures()
                Spacer()
                if s.showsCancel {
                    Button("Cancel") { onCancelScan(s.scanId) }.controlSize(.small).font(.caption)
                }
                if s.showsRetry {
                    Button("Retry") { onScanNow() }.controlSize(.small).font(.caption)
                }
            }
            if let reason = s.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, PS.s1)
    }

    private func color(for state: ScanDTO.State) -> Color {
        switch state {
        case .clean: return PS.safetyColor(forStatus: "green", dark: scheme == .dark)
        case .infected: return .red
        case .failed: return .orange
        case .canceled, .skipped: return .secondary
        case .running: return .primary
        }
    }

    /// Distinct silhouettes per scan state (form, not only hue).
    private func symbol(for state: ScanDTO.State) -> String {
        switch state {
        case .clean: return "checkmark.circle"
        case .infected: return "exclamationmark.octagon.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .canceled, .skipped: return "circle.dashed"
        case .running: return "arrow.triangle.2.circlepath"
        }
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 24)
    }
}
