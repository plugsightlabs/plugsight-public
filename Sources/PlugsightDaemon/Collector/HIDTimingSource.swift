// HIDTimingSource.swift
//
// THIN live plumbing (docs/spec/02): IOHIDManager device matching for the HID
// view — keyboard input TIMING metadata only.
//
// PRIVACY WALL (load-bearing, see PlugsightCore.InputTiming): this source
// emits ONLY a timestamp and an inter-keystroke interval. It never reads,
// stores, or forwards a usage/key code, character, or any typed content. The
// callback intentionally ignores the IOHIDValue beyond "a key went down".
//
// Cannot run in CI (needs real HID hardware + input-monitoring consent); it is
// exercised by the manual probe `ops/dev-attach-probe.swift`.

import Foundation
import IOKit.hid
import PlugsightCore

public final class HIDTimingSource: DeviceEventSource, @unchecked Sendable {

    /// Keys further apart than this start a new burst (interval reported nil).
    private static let burstWindowMs = 2_000

    public var events: AsyncStream<CollectorEvent> { stream }

    private let stream: AsyncStream<CollectorEvent>
    private let continuation: AsyncStream<CollectorEvent>.Continuation

    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var lastKeyAt: Date?

    public init() {
        var continuation: AsyncStream<CollectorEvent>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match keyboards only (Generic Desktop page, Keyboard usage).
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { refcon, _, _, value in
            guard let refcon else { return }
            // Timing only: note that a key went DOWN (non-zero integer value),
            // then drop the value on the floor. No usage, no key code, no
            // content ever leaves this callback.
            guard IOHIDValueGetIntegerValue(value) != 0 else { return }
            Unmanaged<HIDTimingSource>.fromOpaque(refcon).takeUnretainedValue().recordKeyDown()
        }, refcon)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            throw CollectorSourceError.hidManagerOpenFailed(result)
        }
        self.manager = manager
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let manager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        continuation.finish()
    }

    private func recordKeyDown() {
        let now = Date()
        lock.lock()
        let previous = lastKeyAt
        lastKeyAt = now
        lock.unlock()

        let intervalMs: Int?
        if let previous {
            let elapsed = Int(now.timeIntervalSince(previous) * 1000)
            intervalMs = elapsed <= Self.burstWindowMs ? elapsed : nil
        } else {
            intervalMs = nil
        }
        continuation.yield(.inputActivity(InputTiming(at: now, interKeyIntervalMs: intervalMs)))
    }
}
