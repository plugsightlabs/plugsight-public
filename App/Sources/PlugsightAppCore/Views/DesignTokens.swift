// DesignTokens.swift
//
// The shared visual language. Colors are semantic, not brand: the glyph's alert
// state and every severity marker use warning/critical roles, never an accent.
// Figures use tabular numbers (canon). Spacing is an 8pt-ish rhythm so surfaces
// share a cadence and copy is never baked into fixed-width chrome.

import SwiftUI
import PlugsightCore

public enum PS {
    // Spacing rhythm.
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 24
    public static let s6: CGFloat = 32

    // Minimum tap target (Tier 2): rows are 44pt.
    public static let rowHeight: CGFloat = 44

    // Semantic severity colors — NEVER the brand accent for alerts.
    public static func color(forSeverity severity: String) -> Color {
        switch severity {
        case "critical": return .red
        case "warning": return .orange
        case "notice": return .yellow
        case "info": return .secondary
        default: return .secondary
        }
    }

    public static func color(forSeverity severity: DetectionSeverity) -> Color {
        color(forSeverity: severity.rawValue)
    }

    // Severity markers differ by FORM as well as tint (canon: form, not only hue),
    // so a colour-blind reader can tell them apart. Each symbol is a distinct
    // silhouette; the severity is also spoken to VoiceOver via `severityLabel`.
    public static func severitySymbol(forSeverity severity: String) -> String {
        switch severity {
        case "critical": return "exclamationmark.octagon.fill"  // octagon (stop)
        case "warning": return "exclamationmark.triangle.fill"  // triangle
        case "notice": return "diamond.fill"                     // diamond
        case "info": return "circle.fill"                        // circle
        default: return "circle.fill"
        }
    }

    /// The plain severity word spoken to VoiceOver (never a raw token).
    public static func severityLabel(forSeverity severity: String) -> String {
        switch severity {
        case "critical": return "Critical"
        case "warning": return "Warning"
        case "notice": return "Notice"
        case "info": return "Info"
        default: return severity.capitalized
        }
    }

    /// A behavior-tier chip colour pair (foreground, background) that meets WCAG AA
    /// in both light and dark. Yellow-on-pale-yellow (the old "elevated" pairing)
    /// failed the Tier-1 contrast gate, so each tier pairs a readable, darkened
    /// text colour with a low-alpha fill of the same family.
    public static func behaviorChipColors(_ word: String, dark: Bool) -> (foreground: Color, background: Color) {
        switch word {
        case "high":
            return dark
                ? (Color(red: 1.00, green: 0.74, blue: 0.53), Color(red: 0.55, green: 0.22, blue: 0.00).opacity(0.45))
                : (Color(red: 0.60, green: 0.22, blue: 0.00), Color(red: 0.95, green: 0.45, blue: 0.10).opacity(0.16))
        default: // "elevated"
            return dark
                ? (Color(red: 0.98, green: 0.85, blue: 0.45), Color(red: 0.42, green: 0.33, blue: 0.00).opacity(0.55))
                : (Color(red: 0.46, green: 0.34, blue: 0.00), Color(red: 0.85, green: 0.65, blue: 0.00).opacity(0.18))
        }
    }

    // Trust badge tint. Colour is spent only on attention: Flagged earns its
    // orange; Trusted is an all-clear and stays quiet (secondary), never green.
    public static func trustTint(_ tier: TrustTier) -> Color {
        switch tier {
        case .trusted: return .secondary
        case .flagged: return .orange
        case .muted: return .secondary
        case .none: return .secondary
        }
    }
}

/// Render mode. ImageRenderer (the snapshot gate) does not lay out `ScrollView`
/// content, so in snapshot mode the scrollable columns render as a plain
/// top-aligned column — a faithful picture of the top of the list. The live app
/// keeps real scrolling. Set once by the snapshot generator.
public enum PSRender {
    public static var snapshotMode = false
}

/// A column that scrolls at runtime and renders flat for the snapshot gate.
public struct PSScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    public var body: some View {
        if PSRender.snapshotMode {
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView { content() }
        }
    }
}

/// Tabular figures on all numbers (canon).
public struct TabularFigures: ViewModifier {
    public func body(content: Content) -> some View {
        content.monospacedDigit()
    }
}

public extension View {
    func tabularFigures() -> some View { modifier(TabularFigures()) }
}

/// A small pill used for trust badges and quiet behavior tier words.
public struct PSChip: View {
    let text: String
    let tint: Color
    public init(_ text: String, tint: Color) { self.text = text; self.tint = tint }
    public var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, PS.s2)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// The behavior-tier chip ("elevated" / "high"). Unlike the plain `PSChip`, it
/// resolves an AA-compliant text/background pair per tier and per colour scheme,
/// so the word stays legible in light mode (the old yellow-on-pale-yellow failed).
public struct PSBehaviorChip: View {
    let word: String
    @Environment(\.colorScheme) private var scheme
    public init(_ word: String) { self.word = word }
    public var body: some View {
        let pair = PS.behaviorChipColors(word, dark: scheme == .dark)
        Text(word)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, PS.s2)
            .padding(.vertical, 2)
            .background(pair.background, in: Capsule())
            .foregroundStyle(pair.foreground)
    }
}

/// A severity marker that differs by FORM (a distinct silhouette per severity),
/// not tint alone, and names its severity to VoiceOver. Colour-blind and
/// screen-reader users can both tell one severity from another.
public struct PSSeverityDot: View {
    let severity: String
    let size: CGFloat
    public init(_ severity: String, size: CGFloat = 8) {
        self.severity = severity; self.size = size
    }
    public var body: some View {
        Image(systemName: PS.severitySymbol(forSeverity: severity))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(PS.color(forSeverity: severity))
            .accessibilityLabel("\(PS.severityLabel(forSeverity: severity)) severity")
    }
}

/// A reusable empty-state block: a sentence, optionally an action.
public struct PSEmptyState: View {
    let sentence: String
    let actionTitle: String?
    let action: (() -> Void)?
    public init(sentence: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.sentence = sentence; self.actionTitle = actionTitle; self.action = action
    }
    public var body: some View {
        // Top-aligned, not centred in a void: the sentence sits where content
        // would, so a singleton state reads like a surface, not an interstitial.
        VStack(spacing: PS.s3) {
            Text(sentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(PS.s5)
        .padding(.top, PS.s6)
    }
}

/// The store-error shape shared by the window surfaces: what, why, one action.
/// The action renders only when the caller wires a real retry (no dead ends:
/// a painted button that does nothing is worse than no button).
public struct PSStoreError: View {
    let message: String
    let retry: (() -> Void)?
    public init(message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }
    public var body: some View {
        VStack(spacing: PS.s3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message).font(.callout).multilineTextAlignment(.center)
            Text("The event record couldn’t be read. Reopening usually fixes it.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry {
                Button("Reopen", action: retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PS.s5)
    }
}
