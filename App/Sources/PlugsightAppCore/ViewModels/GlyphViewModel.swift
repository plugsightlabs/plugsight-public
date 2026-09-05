// GlyphViewModel.swift
//
// The menu-bar glyph state (04). Four states — idle, degraded, alert, stopped —
// made exclusive by a precedence rule: stopped > alert > degraded > idle. Each
// state carries a SHAPE (form, not only tint) so the glyph reads without colour.
// During startup, before the first heartbeat, the glyph shows stopped-hollow so
// it never claims monitoring that isn't running yet.

import Foundation

public enum GlyphState: String, Equatable, Sendable {
    case idle, degraded, alert, stopped

    /// The FORM each state takes (canon: the four differ in form, not only tint).
    public enum Shape: Equatable, Sendable {
        case monochrome         // idle
        case monochromeWithDot  // degraded
        case tintedWarning      // alert (semantic warning/critical palette, never brand)
        case hollowOutline      // stopped
    }

    public var shape: Shape {
        switch self {
        case .idle: return .monochrome
        case .degraded: return .monochromeWithDot
        case .alert: return .tintedWarning
        case .stopped: return .hollowOutline
        }
    }

    /// A plain-language phrase for VoiceOver, never the raw state token (canon).
    /// The menu-bar item speaks this so a screen-reader user hears a sentence, not
    /// "idle" or "degraded".
    public var accessibilityPhrase: String {
        switch self {
        case .idle: return "monitoring, all clear"
        case .degraded: return "monitoring with reduced coverage"
        case .alert: return "alert, needs attention"
        case .stopped: return "monitoring stopped"
        }
    }
}

public struct GlyphViewModel: Equatable, Sendable {
    /// Resolve the glyph state from status + startup, applying the precedence
    /// rule stopped > alert > degraded > idle.
    ///
    /// `extensionBundled` carries the same honesty gate as the popover footer:
    /// when the daemon says degraded but the ONLY missing grant is a system
    /// extension this build does not ship, the glyph shows idle instead of a
    /// permanent degraded dot nobody can clear. Missing Input Monitoring or a
    /// missing scanner still show degraded.
    public static func state(status: StatusDTO?, startingUp: Bool,
                             extensionBundled: Bool = true) -> GlyphState {
        // Before the first heartbeat the glyph must not claim monitoring.
        if startingUp || status == nil { return .stopped }
        let status = status!
        // Precedence: stopped > alert > degraded > idle.
        if status.monitoring == .stopped { return .stopped }
        if status.activeAlerts > 0 { return .alert }
        if status.monitoring == .degraded,
           GrantNaming.firstMissingGrant(status, extensionBundled: extensionBundled) != nil {
            return .degraded
        }
        return .idle
    }
}
