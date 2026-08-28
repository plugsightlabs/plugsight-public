// GlyphView.swift
//
// The menu-bar glyph, rendered so the FOUR states differ in FORM, not only tint
// (canon): idle is a filled monochrome shield, degraded adds a small dot, alert
// is a filled shield with an exclamation in the semantic warning palette, stopped
// is a hollow (outline) shield. This SwiftUI form is used for the snapshot gate;
// the live app mirrors it with NSImage symbols in AppDelegate.

import SwiftUI

public struct GlyphView: View {
    let state: GlyphState
    public init(state: GlyphState) { self.state = state }

    public var body: some View {
        ZStack {
            switch state {
            case .idle:
                Image(systemName: "shield.fill")
                    .foregroundStyle(.primary)
            case .degraded:
                Image(systemName: "shield.fill")
                    .foregroundStyle(.primary)
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .offset(x: 7, y: -7)
            case .alert:
                // Semantic warning palette, never the brand accent.
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            case .stopped:
                // Hollow outline: monitoring is not running.
                Image(systemName: "shield")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 22, height: 22)
        .accessibilityLabel("Plugsight: \(state.accessibilityPhrase)")
    }
}

/// A labeled row of all four glyph forms, for the snapshot sheet.
public struct GlyphGalleryView: View {
    public init() {}
    public var body: some View {
        HStack(spacing: PS.s5) {
            ForEach([GlyphState.idle, .degraded, .alert, .stopped], id: \.self) { s in
                VStack(spacing: PS.s2) {
                    GlyphView(state: s)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Text(s.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(PS.s5)
    }
}
