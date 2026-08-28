// HIDScorer.swift
//
// N6 daemon-facing scorer wrapper — PURE file (no CoreGraphics import; the
// engine stays portable). Owns the degraded-mode contract (02): when the
// key-timing tap cannot be created (Input Monitoring not granted), the
// scorer reports its capability as false and the daemon keeps running —
// enumeration and mismatch signals still flow, only behavioral scoring is off.

import Foundation
import PlugsightCore

/// Seam for the thin CoreGraphics tap plumbing (CGKeyTimingTap) and for test
/// fakes. PRIVACY WALL: the callback carries a timestamp ONLY — no key code,
/// character, or content can cross this boundary by construction.
public protocol KeyTimingTap: AnyObject {
    /// Try to create/enable the tap. Returns false when the Input Monitoring
    /// grant is missing. Must never throw or crash.
    func start(onKeyDown: @escaping @Sendable (Date) -> Void) -> Bool
    func stop()
}

/// What the scorer can currently do, reported to the daemon/API (02).
public struct ScorerCapability: Equatable, Sendable {
    /// False when the key-timing tap could not be created (grant missing).
    public let behavioralScoring: Bool

    public init(behavioralScoring: Bool) {
        self.behavioralScoring = behavioralScoring
    }
}

/// Daemon-facing wrapper: tap lifecycle + engine, degraded mode when the
/// grant is missing. Serializes all engine access behind a lock, since tap
/// keydowns arrive on the tap's run loop while enumeration events arrive on
/// the daemon's collector task.
public final class HIDScorer: @unchecked Sendable {

    /// Keys further apart than this start a new burst (interval reported nil);
    /// mirrors HIDTimingSource's burst window.
    private static let burstWindowMs = 2_000

    private let engine: ScorerEngine
    private let tap: KeyTimingTap
    /// Findings emitted from tap-driven keydowns (epoch closes triggered by
    /// typing) are delivered here; `ingest`/`finish` return theirs directly.
    private let onFindings: ([ScorerFinding]) -> Void

    private let lock = NSLock()
    private var lastKeyAt: Date?
    private var _capability = ScorerCapability(behavioralScoring: false)

    public private(set) var capability: ScorerCapability {
        get { lock.lock(); defer { lock.unlock() }; return _capability }
        set { lock.lock(); defer { lock.unlock() }; _capability = newValue }
    }

    public init(
        engine: ScorerEngine,
        tap: KeyTimingTap,
        onFindings: @escaping ([ScorerFinding]) -> Void = { _ in }
    ) {
        self.engine = engine
        self.tap = tap
        self.onFindings = onFindings
    }

    /// Start the tap. Never throws: a failed tap (Input Monitoring not
    /// granted) means degraded mode — capability false, daemon keeps running.
    @discardableResult
    public func start() -> ScorerCapability {
        let granted = tap.start { [weak self] at in
            self?.recordKeyDown(at: at)
        }
        let capability = ScorerCapability(behavioralScoring: granted)
        self.capability = capability
        return capability
    }

    public func stop() {
        tap.stop()
        capability = ScorerCapability(behavioralScoring: false)
    }

    /// Forward an enumeration event to the engine (N8's wiring entry point).
    public func ingest(_ event: CollectorEvent) -> [ScorerFinding] {
        lock.lock()
        defer { lock.unlock() }
        return engine.ingest(event)
    }

    /// Close remaining epochs and emit their findings.
    public func finish() -> [ScorerFinding] {
        lock.lock()
        defer { lock.unlock() }
        return engine.finish()
    }

    /// Tap keydown -> timing-only InputTiming (the privacy wall: a timestamp
    /// and an interval, nothing else exists to forward).
    private func recordKeyDown(at now: Date) {
        lock.lock()
        let previous = lastKeyAt
        lastKeyAt = now
        let intervalMs: Int?
        if let previous {
            let elapsed = Int(now.timeIntervalSince(previous) * 1000)
            intervalMs = (elapsed >= 0 && elapsed <= Self.burstWindowMs) ? elapsed : nil
        } else {
            intervalMs = nil
        }
        let findings = engine.ingest(.inputActivity(InputTiming(at: now, interKeyIntervalMs: intervalMs)))
        lock.unlock()
        if !findings.isEmpty { onFindings(findings) }
    }
}
