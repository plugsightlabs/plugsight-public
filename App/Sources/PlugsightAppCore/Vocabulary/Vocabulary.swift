// Vocabulary.swift
//
// The shared vocabulary from 04, written once and rendered by every surface.
// This is where the canon lives in code: `none` displays as "Default", each
// trust tier carries its one-line consequence, the Behavior score renders as a
// number + tier word (low/elevated/high) with its meaning kept OUT of permanent
// prose, and severity thresholds describe themselves. Jargon never appears here.

import Foundation
import PlugsightCore

/// Display + consequence text for trust tiers. `none` → "Default" (canon).
public enum TrustVocabulary {

    /// The segmented-control order the inspector renders (04): Trusted, Default,
    /// Muted, Flagged. `none` sits in the "Default" position.
    public static let displayOrder: [TrustTier] = [.trusted, .none, .muted, .flagged]

    /// The on-screen label. The wire value `none` becomes "Default".
    public static func label(_ tier: TrustTier) -> String {
        switch tier {
        case .trusted: return "Trusted"
        case .none: return "Default"
        case .muted: return "Muted"
        case .flagged: return "Flagged"
        }
    }

    /// The one-line consequence caption shown under the selected segment (04).
    public static func consequence(_ tier: TrustTier) -> String {
        switch tier {
        case .trusted:
            return "Routine alerts off for this device; a critical finding still alerts."
        case .none:
            return "Normal alerting."
        case .muted:
            return "No notifications from this device; everything still recorded."
        case .flagged:
            return "Every event from this device notifies, and it leads lists."
        }
    }

    /// Parse a wire string into a tier, defaulting unknowns to `.none`.
    public static func tier(fromWire wire: String) -> TrustTier {
        TrustTier(rawValue: wire) ?? .none
    }

    /// The one-time forgeability note shown on a user's first-ever trust action (6a).
    public static let firstUseForgeabilityNote =
        "A USB device can lie about who it is, so trusting one is a judgement call. "
        + "Plugsight still records everything and a critical finding will still alert you."
}

/// The shared trust reassurance surfaced in BOTH onboarding and Settings (WP2):
/// one persistent line, straight punctuation, no em dashes.
public enum TrustCopy {
    public static let stayOnMac =
        "Everything stays on your Mac. No cloud, no account, no telemetry. Open source."
}

/// The ClamAV / scanner explanation in simple terms (WP2). Single source for the
/// onboarding scanner step and the Settings Scanner section, so the "why" reads
/// the same in both places.
public enum ScannerCopy {
    public static let explanationHeadline = "Scan drives for malware"
    public static let explanationBody =
        "Plugsight watches how USB devices behave. To also check the files on a drive "
        + "for known malware, it uses ClamAV, a free open-source virus scanner. "
        + "Plugsight can install it for you now. Everything runs on your Mac."
}

/// The honest, non-alarming Input Monitoring reframe (WP2): timing-only, keys
/// never read, nothing leaves the Mac, and a pre-empt of Apple's own dialog copy.
public enum InputMonitoringCopy {
    public static let reframedBody =
        "Plugsight can spot keystroke-injection attacks (a fake keyboard that types by "
        + "itself) by the rhythm of typing. It reads only the timing of keypresses, never "
        + "the keys themselves, and nothing leaves your Mac. macOS will ask to allow this; "
        + "that wording is Apple's, and Plugsight only ever reads timing. This is optional."
    /// The one-sentence capability line for the Settings row (timing-only, honest).
    public static let settingsCapability =
        "Reads only the timing of keypresses (typing rhythm), never the keys themselves, "
        + "to spot keystroke-injection attacks. Nothing leaves your Mac."
}

/// Purpose-led permission labels (WP2): the friendly purpose is the title, the OS
/// permission name is kept as a secondary line so users can still match it in
/// System Settings. One source for onboarding step cards and Settings rows.
public enum PermissionVocabulary {
    public struct Label: Equatable, Sendable {
        public let purpose: String     // the title the user reads first
        public let osName: String      // the OS permission name, shown as secondary
        public init(purpose: String, osName: String) {
            self.purpose = purpose; self.osName = osName
        }
    }
    public static let inputMonitoring = Label(purpose: "Typing-rhythm check",
                                              osName: "Input Monitoring")
    public static let systemExtension = Label(purpose: "Deeper device monitoring",
                                              osName: "System Extension")
    public static let scanner = Label(purpose: "Malware scanning for drives",
                                      osName: "ClamAV scanner")
}

/// The Behavior score presentation (04): a number plus low/elevated/high. The
/// meaning line lives here for tooltips/disclosures — never stacked as prose.
public enum BehaviorVocabulary {
    public static let label = "Behavior"

    public enum Tier: String {
        case low, elevated, high
        public var word: String { rawValue }
    }

    /// Map a 0…100 score to its tier word. Thresholds match the alert ladder
    /// intent: <40 low, 40–69 elevated, >=70 high.
    public static func tier(for score: Int) -> Tier {
        switch score {
        case ..<40: return .low
        case 40..<70: return .elevated
        default: return .high
        }
    }

    /// A quiet tier word is only shown on the Devices row at notice level or
    /// above — i.e. elevated or high. All-clear (low) shows no chip (04).
    public static func rowChipWord(for score: Int) -> String? {
        switch tier(for: score) {
        case .low: return nil
        case .elevated: return Tier.elevated.word
        case .high: return Tier.high.word
        }
    }

    /// The meaning line — tooltip/disclosure only, never permanent prose (04).
    public static let meaning =
        "How much this device’s typing behaves like an automated attack."

    /// The mandatory caveat, present on every score payload (03/charter).
    public static let caveat =
        "Behavioral scoring is probabilistic and a patient attacker can evade it."
}

/// The severity ladder and the self-describing notification threshold options.
public enum SeverityVocabulary {
    /// info < notice < warning < critical (04 shared vocabulary).
    public static let ladder: [DetectionSeverity] = [.info, .notice, .warning, .critical]

    /// The self-describing threshold picker options (04). The wire value is the
    /// key; the label is what the user reads — no ranking-from-memory.
    public struct ThresholdOption: Equatable, Sendable {
        public let wire: String
        public let label: String
    }
    public static let thresholdOptions: [ThresholdOption] = [
        .init(wire: "critical", label: "Only critical"),
        .init(wire: "warning", label: "Warnings and critical"),
        .init(wire: "everything", label: "Everything"),
    ]

    public static func thresholdLabel(forWire wire: String) -> String {
        thresholdOptions.first { $0.wire == wire }?.label ?? "Everything"
    }
}

/// Fallbacks that keep jargon and raw hex off the screen (04/canon).
public enum NamingVocabulary {
    /// A device must never render VID/PID alone as its label (2b). When the
    /// descriptor name is empty/junk, fall back to a plain role-based name.
    public static func displayName(rawName: String?, roleHint: String?) -> String {
        if let rawName, !rawName.trimmingCharacters(in: .whitespaces).isEmpty {
            return rawName
        }
        // Plain fallback keyed on the primary role, never hex.
        if let roleHint, roleHint.contains("keyboard") { return "Unnamed keyboard" }
        if let roleHint, roleHint.contains("mouse") { return "Unnamed pointing device" }
        if let roleHint, roleHint.contains("storage") { return "Unnamed storage device" }
        return "Unnamed device"
    }
}
