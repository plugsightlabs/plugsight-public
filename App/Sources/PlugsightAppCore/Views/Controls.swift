// Controls.swift
//
// Custom SwiftUI renderings of the segmented control, toggle, and checkbox.
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
    /// When set (and enabled), the row is tappable and reports the flipped value
    /// so a live Settings toggle can persist it. Nil keeps the render-only row the
    /// snapshot gallery and gated (display-only) toggles use.
    let onToggle: ((Bool) -> Void)?
    public init(_ title: String, isOn: Bool, enabled: Bool = true,
                onToggle: ((Bool) -> Void)? = nil) {
        self.title = title; self.isOn = isOn; self.enabled = enabled
        self.onToggle = onToggle
    }
    private var track: some View {
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
    public var body: some View {
        if let onToggle, enabled {
            Button { onToggle(!isOn) } label: { track }
                .buttonStyle(.plain)
        } else {
            track
        }
    }
}

/// A labeled checkbox drawn as a square + checkmark so it renders under
/// ImageRenderer. Tappable when `onToggle` is set; render-only otherwise.
public struct PSCheckboxRow: View {
    let title: String
    let isOn: Bool
    let enabled: Bool
    let onToggle: ((Bool) -> Void)?
    public init(_ title: String, isOn: Bool, enabled: Bool = true,
                onToggle: ((Bool) -> Void)? = nil) {
        self.title = title; self.isOn = isOn; self.enabled = enabled
        self.onToggle = onToggle
    }
    private var row: some View {
        HStack(spacing: PS.s2) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isOn ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .opacity(enabled ? 1 : 0.5)
            Text(title).font(.callout)
                .foregroundStyle(enabled ? .primary : .secondary)
            Spacer()
        }
        .frame(minHeight: PS.rowHeight)
    }
    public var body: some View {
        if let onToggle, enabled {
            Button { onToggle(!isOn) } label: { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }
}
