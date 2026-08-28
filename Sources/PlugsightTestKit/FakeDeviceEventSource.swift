import Foundation
import PlugsightCore

/// An array-backed `DeviceEventSource` for tests.
///
/// Constructed with a fixed `[CollectorEvent]`, it exposes an `AsyncStream` that
/// yields those events in order and then finishes. `start()` and `stop()` are
/// trivial. This is the backbone of all later detection tests: build the event
/// script you want, feed it in, and drive the code under test off `events`.
///
/// Thread-safety: the backing array is immutable after init and the stream is
/// built once at init, so this type is safe to hand across the `DeviceEventSource`
/// existential (`Sendable`).
public final class FakeDeviceEventSource: DeviceEventSource, @unchecked Sendable {
    /// The events this source will replay, in order.
    public let scriptedEvents: [CollectorEvent]

    public let events: AsyncStream<CollectorEvent>
    private let continuation: AsyncStream<CollectorEvent>.Continuation

    public init(events: [CollectorEvent]) {
        self.scriptedEvents = events
        var capturedContinuation: AsyncStream<CollectorEvent>.Continuation!
        self.events = AsyncStream<CollectorEvent> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    /// Yields every scripted event in order, then finishes the stream.
    public func start() throws {
        for event in scriptedEvents {
            continuation.yield(event)
        }
        continuation.finish()
    }

    /// Finishes the stream if it has not already finished. Idempotent.
    public func stop() {
        continuation.finish()
    }
}
