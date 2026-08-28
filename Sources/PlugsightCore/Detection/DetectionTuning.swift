// DetectionTuning.swift
//
// FROZEN CONTRACT (07): every 05 detection constant is a named field here,
// additive-only after N3. Consumed by N6. Tuning never hides in call sites:
// `BehavioralScore.compute` and `AlertDecision` take a `tuning:` parameter
// defaulted to `.default`, so there are no magic numbers by construction.
//
// Every value is a 05 starting value to be calibrated during dogfooding,
// not revealed truth.

import Foundation

/// All 05 detection constants, named. Additive-only after N3.
public struct Tuning: Equatable, Sendable {

    // MARK: Plug-to-type latency ramp (signal `plug_to_type_latency`)

    /// Latency at or below this many ms scores full suspicion (1.0).
    public var latencyFullMs: Double
    /// Latency at or above this many ms scores zero suspicion (0.0).
    public var latencyZeroMs: Double

    // MARK: Inter-keystroke timing ramps (signal `inter_key_timing`)

    /// Minimum attributed keystrokes before the timing signal evaluates at all.
    public var minKeystrokesForTiming: Int
    /// Mean inter-key interval at or below this many ms scores 1.0.
    public var meanFullMs: Double
    /// Mean inter-key interval at or above this many ms scores 0.0.
    public var meanZeroMs: Double
    /// Stddev of inter-key intervals at or below this many ms scores 1.0.
    public var stddevFullMs: Double
    /// Stddev of inter-key intervals at or above this many ms scores 0.0.
    public var stddevZeroMs: Double

    // MARK: Signal weights (must sum to 1.0)

    /// Weight of the plug-to-type latency signal.
    public var latencyWeight: Double
    /// Weight of the inter-keystroke timing signal.
    public var timingWeight: Double
    /// Weight of the redundant-keyboard signal.
    public var redundantWeight: Double
    /// Weight of the descriptor-oddity signal.
    public var oddityWeight: Double

    // MARK: Windows (used by N6)

    /// A device epoch opens at attach and closes this many seconds later.
    public var epochWindowSeconds: Int
    /// An already-present keyboard active within this many seconds makes a
    /// new keyboard "redundant".
    public var redundantWindowSeconds: Int

    // MARK: Confidence

    /// High confidence needs at least this many attributed keystrokes.
    public var highConfidenceKeystrokes: Int
    /// A signal above this value counts as "strong" for the confidence ladder.
    public var strongSignalThreshold: Double

    // MARK: Alerting thresholds (policy defaults; 05 trust-tier semantics)

    /// Default tier: score at or above this (with medium+ confidence) raises a warning.
    public var warningScoreThreshold: Int
    /// Default tier: score at or above this (with medium+ confidence) raises a critical.
    public var criticalScoreThreshold: Int
    /// Flagged tier: the behavioral alert threshold drops to this score.
    public var flaggedScoreThreshold: Int

    /// The 05 starting values.
    public static let `default` = Tuning()

    public init(
        latencyFullMs: Double = 500,
        latencyZeroMs: Double = 2000,
        minKeystrokesForTiming: Int = 12,
        meanFullMs: Double = 35,
        meanZeroMs: Double = 80,
        stddevFullMs: Double = 12,
        stddevZeroMs: Double = 40,
        latencyWeight: Double = 0.35,
        timingWeight: Double = 0.35,
        redundantWeight: Double = 0.15,
        oddityWeight: Double = 0.15,
        epochWindowSeconds: Int = 120,
        redundantWindowSeconds: Int = 600,
        highConfidenceKeystrokes: Int = 30,
        strongSignalThreshold: Double = 0.5,
        warningScoreThreshold: Int = 60,
        criticalScoreThreshold: Int = 85,
        flaggedScoreThreshold: Int = 40
    ) {
        self.latencyFullMs = latencyFullMs
        self.latencyZeroMs = latencyZeroMs
        self.minKeystrokesForTiming = minKeystrokesForTiming
        self.meanFullMs = meanFullMs
        self.meanZeroMs = meanZeroMs
        self.stddevFullMs = stddevFullMs
        self.stddevZeroMs = stddevZeroMs
        self.latencyWeight = latencyWeight
        self.timingWeight = timingWeight
        self.redundantWeight = redundantWeight
        self.oddityWeight = oddityWeight
        self.epochWindowSeconds = epochWindowSeconds
        self.redundantWindowSeconds = redundantWindowSeconds
        self.highConfidenceKeystrokes = highConfidenceKeystrokes
        self.strongSignalThreshold = strongSignalThreshold
        self.warningScoreThreshold = warningScoreThreshold
        self.criticalScoreThreshold = criticalScoreThreshold
        self.flaggedScoreThreshold = flaggedScoreThreshold
    }
}
