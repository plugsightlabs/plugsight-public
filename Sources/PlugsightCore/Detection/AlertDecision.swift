// AlertDecision.swift
//
// Trust-tier interaction with detection (05), as a pure function. Deciding
// whether to NOTIFY is separate from recording: every event is recorded
// regardless of tier (the store is N2/N6's job); this type only answers
// "should this notify, and at what effective severity".
//
// 05 semantics, verbatim:
// - trusted: routine alerts (warning and below) suppressed; critical still
//   alerts. Trust raises the bar, it does not close the file (L9).
// - muted:   no notifications at any severity; all recorded; the muted badge
//   keeps the silence legible.
// - flagged: every severity notifies; the behavioral alert threshold drops
//   to score >= flaggedScoreThreshold.
// - none:    defaults (warning at >= warningScoreThreshold with medium+
//   confidence, critical at >= criticalScoreThreshold).

import Foundation

/// Per-device trust tier (05, used verbatim by 03 and 04).
public enum TrustTier: String, Equatable, Sendable, CaseIterable {
    case none, trusted, muted, flagged
}

/// The notify decision for one event or one behavioral score.
public struct AlertDecision: Equatable, Sendable {
    public let shouldAlert: Bool
    /// Severity the notification carries when `shouldAlert` is true.
    public let effectiveSeverity: DetectionSeverity?

    public init(shouldAlert: Bool, effectiveSeverity: DetectionSeverity?) {
        self.shouldAlert = shouldAlert
        self.effectiveSeverity = effectiveSeverity
    }

    private static let suppressed = AlertDecision(shouldAlert: false, effectiveSeverity: nil)

    /// Decision for a severity-carrying event (mismatch rules, scan findings).
    public static func forSeverity(
        _ severity: DetectionSeverity, tier: TrustTier
    ) -> AlertDecision {
        switch tier {
        case .muted:
            return .suppressed
        case .trusted:
            return severity == .critical
                ? AlertDecision(shouldAlert: true, effectiveSeverity: severity)
                : .suppressed
        case .flagged:
            return AlertDecision(shouldAlert: true, effectiveSeverity: severity)
        case .none:
            return severity >= .warning
                ? AlertDecision(shouldAlert: true, effectiveSeverity: severity)
                : .suppressed
        }
    }

    /// Decision for a behavioral score. Low confidence never alerts on its
    /// own — it renders in the device inspector as an observation (05).
    public static func forScore(
        _ score: Int,
        confidence: BehavioralScore.Confidence,
        tier: TrustTier,
        tuning: Tuning = .default
    ) -> AlertDecision {
        guard confidence != .low else { return .suppressed }

        // Map the score to a severity: critical at the critical threshold,
        // warning at the tier's warning threshold (flagged drops it).
        let warningThreshold = tier == .flagged
            ? tuning.flaggedScoreThreshold
            : tuning.warningScoreThreshold
        let severity: DetectionSeverity
        if score >= tuning.criticalScoreThreshold {
            severity = .critical
        } else if score >= warningThreshold {
            severity = .warning
        } else {
            return .suppressed
        }

        return forSeverity(severity, tier: tier)
    }
}
