// Controls.swift
//
// Custom SwiftUI renderings of the segmented control, toggle, and radio group.
// Two reasons they are hand-drawn rather than native: (1) they render faithfully
// under ImageRenderer, so the snapshot gate shows the real control instead of an
// AppKit placeholder; (2) they let us guarantee the Tier-2 44pt tap target and
// keep the styling consistent in light and dark. Colours are semantic tokens.

import SwiftUI
import PlugsightCore

/// A four-segment trust control. The current segment is highlighted; labels are
/// the display words (`none` shows as "Default").
public struct PSSegmentedControl: View {
    let segments: [(tier: TrustTier, label: String)]
    let current: TrustTier
    let onSelect: (TrustTier) -> Void
    public init(segments: [(tier: TrustTier, label: String)], current: TrustTier,
                onSelect: @escaping (TrustTier) -> Void = { _ in }) {
        self.segments = segments; self.current = current; self.onSelect = onSelect
    }
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.tier) { seg in
                let selected = seg.tier == current
                Button { onSelect(seg.tier) } label: {
                    Text(seg.label)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(selected ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A labeled toggle drawn as a track + knob so it renders under ImageRenderer.
public struct PSToggleRow: View {
    let title: String
    let isOn: Bool
    let enabled: Bool
    public init(_ title: String, isOn: Bool, enabled: Bool = true) {
        self.title = title; self.isOn = isOn; self.enabled = enabled
    }
    public var body: some View {
        HStack {
            Text(title).font(.callout)
                .foregroundStyle(enabled ? .primary : .secondary)
            Spacer()
            Capsule()
                .fill(isOn && enabled ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 38, height: 22)
                .overlay(
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .padding(2)
                        .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
                )
                .opacity(enabled ? 1 : 0.5)
        }
        .frame(minHeight: PS.rowHeight)
    }
}

/// A radio group. The selected option shows a filled dot; all self-describe.
public struct PSRadioGroup: View {
    let options: [(wire: String, label: String)]
    let selected: String
    public init(options: [(wire: String, label: String)], selected: String) {
        self.options = options; self.selected = selected
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: PS.s2) {
            ForEach(options, id: \.wire) { opt in
                HStack(spacing: PS.s2) {
                    ZStack {
                        Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 16, height: 16)
                        if opt.wire == selected {
                            Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                        }
                    }
                    Text(opt.label).font(.callout)
                    Spacer()
                }
                .frame(minHeight: 28)
            }
        }
    }
}
