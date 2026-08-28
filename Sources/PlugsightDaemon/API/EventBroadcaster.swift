// EventBroadcaster.swift
//
// The `event.appended` fanout (02: "Every append fans out over event.appended to
// subscribed connections"). N4 owns this in-process bus. Whoever appends an event
// (an API mutation here, the collector/analyzer in the wired daemon, N8) calls
// `publish`; each subscription whose filter matches receives the event on its own
// connection ONLY. Subscriptions are per-connection and removed when it closes.

import Foundation
import PlugsightCore

/// A live tail subscription: an id, the filter it matches against, and a sink
/// that delivers a matching event to one connection.
final class Subscription {
    let id: String
    let filter: TimelineFilter?
    let sink: (StoredEvent) -> Void
    init(id: String, filter: TimelineFilter?, sink: @escaping (StoredEvent) -> Void) {
        self.id = id
        self.filter = filter
        self.sink = sink
    }
}

/// Thread-safe registry + fanout. A single lock guards the table; sinks run
/// outside the lock so a slow/blocking write can never deadlock the bus.
final class EventBroadcaster {
    private let lock = NSLock()
    private var subscriptions: [String: Subscription] = [:]
    private var counter: UInt64 = 0

    /// Register a subscription; returns its id.
    func subscribe(filter: TimelineFilter?, sink: @escaping (StoredEvent) -> Void) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let id = "sub_\(counter)"
        subscriptions[id] = Subscription(id: id, filter: filter, sink: sink)
        return id
    }

    /// Remove one subscription. Returns true if it existed.
    @discardableResult
    func unsubscribe(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return subscriptions.removeValue(forKey: id) != nil
    }

    /// Remove every subscription in the set (a connection closing).
    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for id in ids { subscriptions.removeValue(forKey: id) }
    }

    /// Deliver an event to every matching subscription.
    func publish(_ event: StoredEvent) {
        lock.lock()
        let targets = subscriptions.values.filter { Self.matches($0.filter, event) }
        lock.unlock()
        for sub in targets { sub.sink(event) }
    }

    /// Does an event pass a tail filter? Nil filter matches everything. Mirrors
    /// the timeline.list filter semantics (device, kinds, severity, since/until).
    static func matches(_ filter: TimelineFilter?, _ e: StoredEvent) -> Bool {
        guard let f = filter else { return true }
        if let d = f.deviceId, e.deviceID != d { return false }
        if let kinds = f.kinds, !kinds.isEmpty, !kinds.contains(e.kind) { return false }
        if let sev = f.severity, e.severity != sev { return false }
        if let since = f.since, e.at < since { return false }
        if let until = f.until, e.at > until { return false }
        return true
    }
}
