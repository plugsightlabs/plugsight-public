// ScorerEngine.swift
//
// N6 HID scorer engine — PURE (02): consumes the seam (`CollectorEvent`),
// produces score results and the timeline events N8 will persist. No DB
// connection, no CoreGraphics, no IOKit — this file must stay portable.
//
// Semantics (05):
// - A device epoch opens when a HID-capable device attaches (an interface
//   with usbClass 0x03, usbProtocol 0x01 — a keyboard) and closes
//   `epochWindow` (120 s) later, or at detach, whichever comes first.
// - Keystrokes (`inputActivity`, timing only) inside the epoch are attributed
//   to that device. When TWO epochs overlap the same keystroke, attribution
//   is ambiguous: both epochs are marked and confidence is forced low —
//   never guess silently.
// - Per closed epoch with at least one attributed keystroke, the engine
//   emits the events N8 will persist: `hid.typing_burst` (notice) and
//   `score.changed` (severity from the default-tier AlertDecision; N8
//   re-decides with the device's real trust tier).
//
// Timestamp contract: the seam's `.attached` carries no timestamp (a live
// attach IS "now"), so the engine stamps every `.attached` with its injected
// `clock` — exactly once per attach, which is what keeps the TestKit
// stepping clock deterministic.

import Foundation
import PlugsightCore

/// Per-burst behavioral inputs, reported alongside every finding so the
/// timeline can explain the score line by line (05).
public struct BurstStats: Equatable, Sendable {
    public let keystrokes: Int
    public let firstKeyLatencyMs: Int
    public let meanIntervalMs: Double
    public let stddevIntervalMs: Double
    public let redundantKeyboard: Bool
    public let descriptorOddity: Bool
    public let ambiguousAttribution: Bool

    public init(
        keystrokes: Int,
        firstKeyLatencyMs: Int,
        meanIntervalMs: Double,
        stddevIntervalMs: Double,
        redundantKeyboard: Bool,
        descriptorOddity: Bool,
        ambiguousAttribution: Bool
    ) {
        self.keystrokes = keystrokes
        self.firstKeyLatencyMs = firstKeyLatencyMs
        self.meanIntervalMs = meanIntervalMs
        self.stddevIntervalMs = stddevIntervalMs
        self.redundantKeyboard = redundantKeyboard
        self.descriptorOddity = descriptorOddity
        self.ambiguousAttribution = ambiguousAttribution
    }
}

/// One timeline event the scorer wants persisted (N8's job — the engine
/// NEVER writes the store itself).
public struct ScorerFinding: Equatable, Sendable {
    /// "hid.typing_burst" (notice) or "score.changed" (06 event kinds).
    public let kind: String
    /// Default-tier severity string ("notice"/"warning"/"critical"). N8
    /// re-runs AlertDecision with the device's real trust tier before alerting.
    public let severity: String
    public let deviceKey: String
    public let at: Date
    public let summary: String
    public let burst: BurstStats
    /// Present on "score.changed": score + confidence + per-signal breakdown.
    public let score: BehavioralScore?

    public init(
        kind: String,
        severity: String,
        deviceKey: String,
        at: Date,
        summary: String,
        burst: BurstStats,
        score: BehavioralScore?
    ) {
        self.kind = kind
        self.severity = severity
        self.deviceKey = deviceKey
        self.at = at
        self.summary = summary
        self.burst = burst
        self.score = score
    }
}

/// The pure scorer engine: device epochs, attribution, behavioral scoring.
///
/// Single-consumer by design (one seam stream); not thread-safe on its own.
/// `HIDScorer` serializes concurrent access where the live tap is involved.
public final class ScorerEngine {

    private struct Epoch {
        let deviceKey: String
        let attachedAt: Date
        let closesAt: Date
        let redundantKeyboard: Bool
        let descriptorOddity: Bool
        var ambiguous = false
        var firstKeyAt: Date?
        var lastKeyAt: Date?
        var keystrokes = 0
        var intervalsMs: [Int] = []

        func contains(_ at: Date) -> Bool {
            at >= attachedAt && at <= closesAt
        }
    }

    private let tuning: Tuning
    private let clock: () -> Date
    private let descriptorOddity: (DeviceDescriptor) -> Bool

    private var openEpochs: [Epoch] = []
    /// Last keyboard activity seen from ANY keyboard (feeds the
    /// redundant-keyboard flag for later attaches).
    private var lastKeyboardActivityAt: Date?

    public init(
        tuning: Tuning = .default,
        clock: @escaping () -> Date = Date.init,
        descriptorOddity: @escaping (DeviceDescriptor) -> Bool = { _ in false }
    ) {
        self.tuning = tuning
        self.clock = clock
        self.descriptorOddity = descriptorOddity
    }

    /// Feed one seam event; returns any findings emitted by epochs that
    /// closed as a result.
    public func ingest(_ event: CollectorEvent) -> [ScorerFinding] {
        switch event {
        case .attached(let device):
            // Exactly one clock() call per .attached — the TestKit stepping
            // clock relies on this.
            let now = clock()
            var findings = closeExpiredEpochs(asOf: now)
            guard isHIDKeyboard(device) else { return findings }
            let redundant = lastKeyboardActivityAt.map {
                now >= $0 && now.timeIntervalSince($0) <= Double(tuning.redundantWindowSeconds)
            } ?? false
            openEpochs.append(Epoch(
                deviceKey: device.deviceKey,
                attachedAt: now,
                closesAt: now.addingTimeInterval(Double(tuning.epochWindowSeconds)),
                redundantKeyboard: redundant,
                descriptorOddity: descriptorOddity(device)
            ))
            return findings

        case .inputActivity(let timing):
            // Expired epochs close FIRST, so a key past the window is never
            // attributed to them.
            var findings = closeExpiredEpochs(asOf: timing.at)
            let matching = openEpochs.indices.filter { openEpochs[$0].contains(timing.at) }
            if matching.count >= 2 {
                // Two keyboards typing in the same window: attribution is
                // ambiguous. Mark every involved epoch; confidence is forced
                // low downstream. Never guess silently (05).
                for index in matching { openEpochs[index].ambiguous = true }
            }
            for index in matching { attribute(timing, toEpochAt: index) }
            lastKeyboardActivityAt = timing.at
            return findings

        case .detached(let deviceKey, let at):
            var findings = closeExpiredEpochs(asOf: at)
            while let index = openEpochs.firstIndex(where: { $0.deviceKey == deviceKey }) {
                findings += close(openEpochs.remove(at: index), at: at)
            }
            return findings

        case .interfacesRead, .volumeMounted, .volumeUnmounted:
            return []
        }
    }

    /// Close every remaining epoch (stream end) and emit its findings.
    public func finish() -> [ScorerFinding] {
        let epochs = openEpochs
        openEpochs = []
        return epochs.flatMap { close($0, at: $0.lastKeyAt ?? $0.attachedAt) }
    }

    /// Drive the engine from the real seam: consume the stream, then finish.
    public func score(_ stream: AsyncStream<CollectorEvent>) async -> [ScorerFinding] {
        var findings: [ScorerFinding] = []
        for await event in stream {
            findings += ingest(event)
        }
        findings += finish()
        return findings
    }

    // MARK: - Internals

    private func isHIDKeyboard(_ device: DeviceDescriptor) -> Bool {
        device.interfaces.contains { $0.usbClass == 0x03 && $0.usbProtocol == 0x01 }
    }

    private func attribute(_ timing: InputTiming, toEpochAt index: Int) {
        if openEpochs[index].firstKeyAt == nil {
            openEpochs[index].firstKeyAt = timing.at
        }
        openEpochs[index].lastKeyAt = timing.at
        openEpochs[index].keystrokes += 1
        if let interval = timing.interKeyIntervalMs {
            openEpochs[index].intervalsMs.append(interval)
        }
    }

    private func closeExpiredEpochs(asOf now: Date) -> [ScorerFinding] {
        var findings: [ScorerFinding] = []
        while let index = openEpochs.firstIndex(where: { $0.closesAt < now }) {
            let epoch = openEpochs.remove(at: index)
            findings += close(epoch, at: epoch.closesAt)
        }
        return findings
    }

    /// Emit the epoch's findings: nothing typed means nothing to report.
    private func close(_ epoch: Epoch, at closedAt: Date) -> [ScorerFinding] {
        guard epoch.keystrokes > 0, let firstKeyAt = epoch.firstKeyAt else { return [] }
        let lastKeyAt = epoch.lastKeyAt ?? firstKeyAt

        let latencyMs = firstKeyAt.timeIntervalSince(epoch.attachedAt) * 1000
        let mean = mean(of: epoch.intervalsMs)
        let stddev = populationStddev(of: epoch.intervalsMs, mean: mean)

        let score = BehavioralScore.compute(
            latencyMs: latencyMs,
            meanIKIMs: mean,
            stddevIKIMs: stddev,
            keystrokes: epoch.keystrokes,
            intervalCount: epoch.intervalsMs.count,
            redundantKeyboard: epoch.redundantKeyboard,
            descriptorOddity: epoch.descriptorOddity,
            ambiguousAttribution: epoch.ambiguous,
            tuning: tuning
        )

        let stats = BurstStats(
            keystrokes: epoch.keystrokes,
            firstKeyLatencyMs: Int(latencyMs.rounded()),
            meanIntervalMs: mean,
            stddevIntervalMs: stddev,
            redundantKeyboard: epoch.redundantKeyboard,
            descriptorOddity: epoch.descriptorOddity,
            ambiguousAttribution: epoch.ambiguous
        )

        let durationSeconds = lastKeyAt.timeIntervalSince(firstKeyAt)
        let burstSummary = String(
            format: "Typed %d keys in %.1f s, starting %.1f s after plug-in.",
            epoch.keystrokes, durationSeconds, latencyMs / 1000
        )

        // Default-tier severity for the timeline row; low confidence and
        // sub-threshold scores stay "notice". N8 re-runs AlertDecision with
        // the device's real trust tier before notifying anyone.
        let decision = AlertDecision.forScore(
            score.score, confidence: score.confidence, tier: .none, tuning: tuning
        )
        let scoreSeverity = decision.effectiveSeverity?.rawValue ?? DetectionSeverity.notice.rawValue
        let scoreSummary = "Behavior score \(score.score) (\(score.confidence.rawValue) confidence)."

        return [
            ScorerFinding(
                kind: "hid.typing_burst",
                severity: DetectionSeverity.notice.rawValue,
                deviceKey: epoch.deviceKey,
                at: lastKeyAt,
                summary: burstSummary,
                burst: stats,
                score: nil
            ),
            ScorerFinding(
                kind: "score.changed",
                severity: scoreSeverity,
                deviceKey: epoch.deviceKey,
                at: closedAt,
                summary: scoreSummary,
                burst: stats,
                score: score
            ),
        ]
    }

    private func mean(of values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private func populationStddev(of values: [Int], mean: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let variance = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
            / Double(values.count)
        return variance.squareRoot()
    }
}
