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
    /// above. All-clear (low) shows no chip (04). The words are plain language,
    /// never internal tier tokens: "elevated" reads as "unusual typing".
    public static func rowChipWord(for score: Int) -> String? {
        switch tier(for: score) {
        case .low: return nil
        case .elevated: return "unusual typing"
        case .high: return "high"
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

/// The verdict action vocabulary (04 verdict model). The daemon sends one
/// recommended action per safety reason as a raw string; this maps it to the
/// exact UI the inspector renders: a working button, an inline list, or plain
/// advice text. Unknown wire values degrade to advice-free text (an older app
/// never renders a dead control for a newer daemon's vocabulary).
public enum SafetyAction: Equatable, Sendable {
    case scanAgain
    case reviewQuarantine
    case reviewAlerts
    case grantInputMonitoring
    case installScanner
    case unplug
    case none
    case other(String)

    public init(wire: String) {
        switch wire {
        case "scanAgain": self = .scanAgain
        case "reviewQuarantine": self = .reviewQuarantine
        case "reviewAlerts": self = .reviewAlerts
        case "grantInputMonitoring": self = .grantInputMonitoring
        case "installScanner": self = .installScanner
        case "unplug": self = .unplug
        case "none": self = .none
        default: self = .other(wire)
        }
    }

    /// The label for the actions that render as ONE working button. nil means
    /// the action renders as an inline list (quarantine, alerts) or as advice.
    public var buttonLabel: String? {
        switch self {
        case .scanAgain: return "Scan again"
        case .grantInputMonitoring: return "Turn on Input Monitoring"
        default: return nil
        }
    }

    /// Advice text for actions that are guidance, not a button. The scanner
    /// install lives in Settings, so the reason points there instead of
    /// duplicating the install flow; unplug is advice by design (detector,
    /// not blocker).
    public var adviceText: String? {
        switch self {
        case .installScanner:
            return "Install the scanner in Settings, under Scanner."
        case .unplug:
            return "If you were not expecting this device, unplug it."
        default:
            return nil
        }
    }
}

/// Scan state words (04): plain language, never the wire token. "infected"
/// reads as "Malware found"; "running" as "Scanning".
public enum ScanVocabulary {
    public static func stateWord(_ state: ScanDTO.State) -> String {
        switch state {
        case .running: return "Scanning"
        case .clean: return "Clean"
        case .infected: return "Malware found"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        case .skipped: return "Skipped"
        }
    }
}

public extension TimeFormatting {
    /// Compact local display for table cells: "Today 9:14 AM", "Yesterday
    /// 6:40 PM", else "Aug 20, 2026, 9:14 AM". Parsed and rendered in the
    /// viewer's local timezone; an unparseable input falls back to itself.
    static func compact(_ iso: String, now: Date = Date(),
                        timeZone: TimeZone = .current) -> String {
        guard parseISO(iso) != nil else { return iso }
        let label = dayLabel(forDayKey: dayKey(iso, timeZone: timeZone),
                             now: now, timeZone: timeZone)
        let time = timeOnly(iso, timeZone: timeZone)
        if label == "Today" || label == "Yesterday" { return "\(label) \(time)" }
        return "\(label), \(time)"
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
