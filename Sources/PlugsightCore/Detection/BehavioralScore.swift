// BehavioralScore.swift
//
// The behavioral HID score (05): pure math over timing facts, no platform
// imports, every constant read from Tuning. Stated up front, per the charter:
// this score is probabilistic and evadable — a patient implant that waits and
// types at human cadence scores low, and the test suite asserts that honestly
// (testPatientImplantEvadesAndWeSaySo).
//
//   score = round(100 * (0.35*s_latency + 0.35*s_timing
//                        + 0.15*s_redundant + 0.15*s_oddity))

import Foundation

/// Result of scoring one device epoch's behavioral signals.
public struct BehavioralScore: Equatable, Sendable {

    /// Evidence volume and agreement, reported alongside every score.
    public enum Confidence: String, Equatable, Sendable {
        case low, medium, high
    }

    /// The four unit signals (each in [0, 1]), exposed so alerts can explain
    /// the score line by line instead of presenting a bare number.
    public struct Signals: Equatable, Sendable {
        public let latency: Double
        public let timing: Double
        public let redundant: Double
        public let oddity: Double

        public init(latency: Double, timing: Double, redundant: Double, oddity: Double) {
            self.latency = latency
            self.timing = timing
            self.redundant = redundant
            self.oddity = oddity
        }
    }

    /// 0...100.
    public let score: Int
    public let confidence: Confidence
    public let signals: Signals

    public init(score: Int, confidence: Confidence, signals: Signals) {
        self.score = score
        self.confidence = confidence
        self.signals = signals
    }

    /// Compute the behavioral score for one device epoch.
    ///
    /// - Parameters:
    ///   - latencyMs: plug-to-type latency (first keystroke after enumeration).
    ///   - meanIKIMs: mean inter-keystroke interval over the burst.
    ///   - stddevIKIMs: standard deviation of the inter-keystroke intervals.
    ///   - keystrokes: attributed keystroke count for the epoch.
    ///   - intervalCount: size of the inter-keystroke interval sample the mean
    ///     and stddev were computed over. The timing signal gates on THIS, not
    ///     on `keystrokes`: a deliberate typist can cross the keystroke gate
    ///     while every inter-key gap is dropped as out-of-burst, leaving an
    ///     empty sample whose mean and stddev are both 0 and would otherwise
    ///     read as maximal injector cadence. Pass nil (the default) only when
    ///     the sample size is not measured; the pure math tests do this and the
    ///     signal then falls back to the keystroke gate alone.
    ///   - redundantKeyboard: another keyboard was active within the redundant
    ///     window when this one attached.
    ///   - descriptorOddity: R6 fired, or the HID report descriptor is the
    ///     common injector boilerplate.
    ///   - ambiguousAttribution: attribution is ambiguous (two keyboards typing
    ///     in the same window); forces low confidence, never guesses silently.
    ///   - tuning: every constant, named (no magic numbers by construction).
    public static func compute(
        latencyMs: Double,
        meanIKIMs: Double,
        stddevIKIMs: Double,
        keystrokes: Int,
        intervalCount: Int? = nil,
        redundantKeyboard: Bool,
        descriptorOddity: Bool,
        ambiguousAttribution: Bool = false,
        tuning: Tuning = .default
    ) -> BehavioralScore {
        // s_latency: linear ramp, 1.0 at <= latencyFullMs, 0.0 at >= latencyZeroMs.
        let sLatency = descendingRamp(latencyMs, full: tuning.latencyFullMs, zero: tuning.latencyZeroMs)

        // s_timing: max of the mean and stddev ramps, gated on the INTERVAL
        // SAMPLE, not the raw keystroke count. A genuine burst of N keystrokes
        // yields N-1 intervals, so a >= minKeystrokesForTiming burst produces
        // >= minKeystrokesForTiming - 1 intervals; anything thinner (an empty
        // or near-empty sample from a slow typist whose gaps were all dropped
        // as out-of-burst) cannot be judged for cadence and contributes zero,
        // exactly like the sub-minKeystrokesForTiming case. nil intervalCount
        // means "not measured" and falls back to the keystroke gate alone.
        let sTiming: Double
        let minIntervals = tuning.minKeystrokesForTiming - 1
        let sufficientIntervalSample = (intervalCount ?? Int.max) >= minIntervals
        if keystrokes >= tuning.minKeystrokesForTiming && sufficientIntervalSample {
            let sMean = descendingRamp(meanIKIMs, full: tuning.meanFullMs, zero: tuning.meanZeroMs)
            let sStddev = descendingRamp(stddevIKIMs, full: tuning.stddevFullMs, zero: tuning.stddevZeroMs)
            sTiming = max(sMean, sStddev)
        } else {
            sTiming = 0
        }

        let sRedundant: Double = redundantKeyboard ? 1 : 0
        let sOddity: Double = descriptorOddity ? 1 : 0

        let weighted = tuning.latencyWeight * sLatency
            + tuning.timingWeight * sTiming
            + tuning.redundantWeight * sRedundant
            + tuning.oddityWeight * sOddity
        let score = Int((100 * weighted).rounded(.toNearestOrAwayFromZero))

        let signals = Signals(latency: sLatency, timing: sTiming, redundant: sRedundant, oddity: sOddity)

        // Confidence ladder (05):
        //   low:    < minKeystrokesForTiming keys, or ambiguous attribution
        //   high:   >= highConfidenceKeystrokes keys AND >= 2 signals strong
        //   medium: otherwise
        let confidence: Confidence
        if ambiguousAttribution || keystrokes < tuning.minKeystrokesForTiming {
            confidence = .low
        } else {
            let strongSignals = [sLatency, sTiming, sRedundant, sOddity]
                .filter { $0 > tuning.strongSignalThreshold }
                .count
            if keystrokes >= tuning.highConfidenceKeystrokes && strongSignals >= 2 {
                confidence = .high
            } else {
                confidence = .medium
            }
        }

        return BehavioralScore(score: score, confidence: confidence, signals: signals)
    }

    /// Linear ramp that is 1.0 at or below `full`, 0.0 at or above `zero`,
    /// and (zero - value)/(zero - full) in between; clamped to [0, 1].
    private static func descendingRamp(_ value: Double, full: Double, zero: Double) -> Double {
        if value <= full { return 1 }
        if value >= zero { return 0 }
        return (zero - value) / (zero - full)
    }
}
