// CompositeDeviceEventSource.swift  (N8)
//
// Merge several `DeviceEventSource`s (IOKit enumeration, HID timing,
// DiskArbitration volumes) into ONE seam stream for the analyzer loop.
// Platform-neutral: it only forwards `CollectorEvent`s.
//
// Lifecycle: `start()` starts every child and one forwarding task per child;
// the merged stream finishes when `stop()` is called (which stops the
// children). With zero children (the seeded/roundtrip boot, N8-G) the stream
// simply stays open until stopped.

import Foundation
import PlugsightCore

public final class CompositeDeviceEventSource: DeviceEventSource, @unchecked Sendable {

    public let events: AsyncStream<CollectorEvent>
    private let continuation: AsyncStream<CollectorEvent>.Continuation

    private let sources: [DeviceEventSource]
    private let lock = NSLock()
    private var forwarders: [Task<Void, Never>] = []
    private var stoppedFlag = false

    public init(sources: [DeviceEventSource]) {
        self.sources = sources
        var captured: AsyncStream<CollectorEvent>.Continuation!
        self.events = AsyncStream<CollectorEvent> { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    deinit { stop() }

    /// Start every child source and forward its events into the merged stream.
    /// A child that fails to start is reported to the caller; children started
    /// before it keep running (degraded operation beats none).
    public func start() throws {
        var firstError: Error?
        for source in sources {
            do {
                try source.start()
            } catch {
                firstError = firstError ?? error
                continue
            }
            let task = Task { [continuation] in
                for await event in source.events {
                    continuation.yield(event)
                }
            }
            lock.lock()
            forwarders.append(task)
            lock.unlock()
        }
        if let firstError { throw firstError }
    }

    /// Stop the children, cancel the forwarders, and finish the merged stream.
    /// Idempotent.
    public func stop() {
        lock.lock()
        let alreadyStopped = stoppedFlag
        stoppedFlag = true
        let tasks = forwarders
        forwarders = []
        lock.unlock()
        guard !alreadyStopped else { return }

        for source in sources { source.stop() }
        for task in tasks { task.cancel() }
        continuation.finish()
    }
}
