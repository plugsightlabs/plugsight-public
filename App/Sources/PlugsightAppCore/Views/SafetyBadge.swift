// SafetyBadge.swift
//
// The one visual answer to "is this device safe?": a distinct silhouette per
// verdict (form, not only hue) plus the plain verdict word. Green stays quiet
// (canon: an all-clear state does not shout), grey is "not checked", never a
// danger tint. Shared by the devices table, the inspector, and the popover so
// the same job never gets two visual answers.

import SwiftUI

public extension PS {
    /// The plain verdict word for a wire safety status ("green" | "yellow" | "red" | "grey").
    static func safetyWord(forStatus status: String) -> String {
        switch status {
        case "green": return "Safe"
        case "yellow": return "Needs attention"
        case "red": return "Unsafe"
        case "grey": return "Not checked"
        default: return "Not checked"
        }
    }

    /// Verdict silhouettes: check circle / triangle / octagon / dashed circle.
    static func safetySymbol(forStatus status: String) -> String {
        switch status {
        case "green": return "checkmark.circle"
        case "yellow": return "exclamationmark.triangle.fill"
        case "red": return "exclamationmark.octagon.fill"
        case "grey": return "circle.dashed"
        default: return "circle.dashed"
        }
    }

    /// Verdict tint, used for ICONS only — never for text (owner feedback:
    /// "loose the neon color scheme"). Green is deliberately muted one step
    /// further than the original palette; grey carries no urgency.
    static func safetyColor(forStatus status: String, dark: Bool) -> Color {
        switch status {
        case "green":
            return dark ? Color(red: 0.33, green: 0.62, blue: 0.42) : Color(red: 0.15, green: 0.45, blue: 0.24)
        case "yellow":
            return dark ? Color(red: 0.98, green: 0.80, blue: 0.30) : Color(red: 0.55, green: 0.40, blue: 0.00)
        case "red":
            return dark ? Color(red: 1.00, green: 0.42, blue: 0.38) : Color(red: 0.75, green: 0.13, blue: 0.10)
        default:
            return .secondary
        }
    }
}

/// Icon + word, never colour alone. `compact` drops to icon size 11 and caption
/// type for dense table rows; the verdict word is always present and is also the
/// VoiceOver label, so the status reads the same to eyes and screen readers.
public struct PSSafetyBadge: View {
    let status: String
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    public init(_ status: String, compact: Bool = false) {
        self.status = status; self.compact = compact
    }
    public var body: some View {
        let tint = PS.safetyColor(forStatus: status, dark: scheme == .dark)
        // Tinted icon + PRIMARY-COLOR word (de-neon): the status still reads as
        // icon + word, never colour alone, but the text no longer glows.
        HStack(spacing: PS.s1) {
            Image(systemName: PS.safetySymbol(forStatus: status))
                .font(.system(size: compact ? 11 : 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(PS.safetyWord(forStatus: status))
                .font(compact ? .caption.weight(.medium) : .callout.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PS.safetyWord(forStatus: status))
    }
}
