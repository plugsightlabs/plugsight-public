// DeviceInspectorView.swift
//
// The device inspector pane (04). Identity header, then the Behavior card (which
// honors null-not-zero: no number when the sensor is off or nothing was typed),
// then the trust control (four segments, `none` shown as Default, its consequence
// as the caption), then scan records with Restore / Retry / Cancel. The Behavior
// meaning line and caveat live in the disclosure, never as permanent prose.

import SwiftUI
import PlugsightCore

public struct DeviceInspectorView: View {
    let state: InspectorState
    // Interaction seams. Defaults keep the snapshot/preview path (state-only) intact;
    // the live host (InspectorHost) passes the view model's callbacks and published
    // undo/error state so the trust write, the undo toast, and the write-error render
    // path are all reached.
    let undoToast: UndoToast?
    let trustWriteError: String?
    let onSetTrust: (TrustTier) -> Void
    let onUndo: () -> Void
    let onDismissUndo: () -> Void
    let onDismissError: () -> Void

    public init(state: InspectorState,
                undoToast: UndoToast? = nil,
                trustWriteError: String? = nil,
                onSetTrust: @escaping (TrustTier) -> Void = { _ in },
                onUndo: @escaping () -> Void = {},
                onDismissUndo: @escaping () -> Void = {},
                onDismissError: @escaping () -> Void = {}) {
        self.state = state
        self.undoToast = undoToast
        self.trustWriteError = trustWriteError
        self.onSetTrust = onSetTrust
        self.onUndo = onUndo
        self.onDismissUndo = onDismissUndo
        self.onDismissError = onDismissError
    }

    public var body: some View {
        switch state {
        case .loading:
            VStack(spacing: PS.s3) { ForEach(0..<3, id: \.self) { _ in card { skeleton } } }.padding(PS.s4)
        case .notFound(let msg), .storeError(let msg):
            PSStoreError(message: msg)
        case .loaded(let l):
            ZStack(alignment: .bottom) {
                PSScroll {
                    VStack(alignment: .leading, spacing: PS.s4) {
                        identityHeader(l.header)
                        behaviorCard(l.behavior)
                        trustControl(l.trust)
                        if !l.scans.isEmpty {
                            scansCard(l.scans)
                        }
                    }
                    .padding(PS.s4)
                }
                if let toast = undoToast {
                    undoToastView(toast)
                }
            }
        }
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
            HStack {
                VStack(alignment: .leading, spacing: PS.s1) {
                    Text(h.name).font(.title3.weight(.semibold))
                    Text(h.rolesText).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if h.showsEject {
                    Button("Eject") {}.controlSize(.small)
                }
            }
            HStack(spacing: PS.s3) {
                Text(h.vidPid).font(.caption).foregroundStyle(.secondary).tabularFigures()
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
                                    .foregroundStyle(s.verdict == "clear" ? .green : .orange)
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
                Button("Turn on Input Monitoring") {}.controlSize(.small).font(.caption)
            case .noData(let msg):
                Text(msg).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func trustControl(_ t: TrustControlVM) -> some View {
        card {
            Text("TRUST").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            PSSegmentedControl(segments: t.segments.map { ($0.tier, $0.label) },
                               current: t.current, onSelect: onSetTrust)
            if let seg = t.segments.first(where: { $0.tier == t.current }) {
                Text(seg.consequence).font(.caption).foregroundStyle(.secondary)
            }
            // A failed trust write never destroys the selection: the reason renders
            // inline here, next to the control, with a dismiss.
            if let error = trustWriteError {
                HStack(alignment: .firstTextBaseline, spacing: PS.s2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.primary)
                    Spacer(minLength: PS.s2)
                    Button("Dismiss") { onDismissError() }.controlSize(.small).font(.caption2)
                }
                .padding(PS.s2)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Trust not saved: \(error)")
            }
            if t.showForgeabilityNote {
                Label(TrustVocabulary.firstUseForgeabilityNote, systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(PS.s2)
                    .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func scansCard(_ scans: [ScanRecordVM]) -> some View {
        card {
            Text("SCANS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(scans) { s in
                VStack(alignment: .leading, spacing: PS.s1) {
                    HStack {
                        Text(s.stateWord.capitalized).font(.callout.weight(.medium))
                            .foregroundStyle(color(for: s.state))
                        if let p = s.progress {
                            Text("\(Int(p * 100))%").font(.caption).tabularFigures().foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.showsCancel { Button("Cancel") {}.controlSize(.small).font(.caption) }
                        if s.showsRetry { Button("Retry") {}.controlSize(.small).font(.caption) }
                    }
                    if let reason = s.reason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(s.quarantine, id: \.quarantineId) { q in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(q.filePath).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Restore") {}.controlSize(.small).font(.caption)
                        }
                    }
                }
                .padding(.vertical, PS.s1)
            }
        }
    }

    private func color(for state: ScanDTO.State) -> Color {
        switch state {
        case .clean: return .green
        case .infected: return .red
        case .failed: return .orange
        case .canceled, .skipped: return .secondary
        case .running: return .primary
        }
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(height: 24)
    }
}
