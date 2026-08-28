// CGKeyTimingTap.swift
//
// THIN live plumbing (02): the listen-only CGEventTap under the Input
// Monitoring grant. This is the ONLY Scorer file allowed to import
// CoreGraphics — the engine and HIDScorer stay portable (the seam gate
// checks PlugsightCore; this daemon-target import is fine, but the pure
// files keep it out anyway).
//
// PRIVACY WALL (load-bearing, see PlugsightCore.InputTiming): the callback
// notes THAT a key went down and WHEN. It never reads the event's key code,
// flags, or characters — no content exists past this point by construction.
//
// Cannot run in CI (needs the Input Monitoring grant); the degraded path
// (tap creation returns nil -> start() returns false) is what ScorerTests
// exercises through the KeyTimingTap seam.

import Foundation
import CoreGraphics
import PlugsightCore

public final class CGKeyTimingTap: KeyTimingTap, @unchecked Sendable {

    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onKeyDown: (@Sendable (Date) -> Void)?

    public init() {}

    deinit { stop() }

    /// Create and enable the listen-only key-down tap. Returns false when
    /// tap creation fails (Input Monitoring not granted) — degraded mode,
    /// never a throw or a crash.
    public func start(onKeyDown: @escaping @Sendable (Date) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if port != nil { return true }
        self.onKeyDown = onKeyDown

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<CGKeyTimingTap>.fromOpaque(refcon).takeUnretainedValue()
                switch type {
                case .keyDown:
                    // Timing only: the CGEvent's key code / characters are
                    // deliberately never read.
                    tap.handleKeyDown()
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    tap.reenable()
                default:
                    break
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            // Input Monitoring not granted: report the capability honestly.
            self.onKeyDown = nil
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.runLoopSource = source
        return true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(port)
        self.port = nil
        self.runLoopSource = nil
        self.onKeyDown = nil
    }

    private func handleKeyDown() {
        lock.lock()
        let handler = onKeyDown
        lock.unlock()
        handler?(Date())
    }

    /// The OS disables listen-only taps it deems slow; re-enable and move on.
    private func reenable() {
        lock.lock()
        defer { lock.unlock() }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }
}
