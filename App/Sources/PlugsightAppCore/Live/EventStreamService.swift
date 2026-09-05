// EventStreamService.swift
//
// The one long-lived tail subscription over the local API (02 subscription
// model), owned by the AppDelegate. It subscribes via events.tail, keeps the
// connection pumped so `event.appended` pushes flow, and feeds each event to
// (a) the NotificationManager and (b) the RefreshCoordinator the main window
// observes. When the daemon connection drops it reconnects with a small fixed
// delay and re-tails, first untailing the stale subscription locally so a
// reconnect never leaves a duplicate delivery path behind.
//
// The popover's existing 5 s status poll is untouched; this stream only serves
// notifications and the main-window live refresh.

import Foundation

public actor EventStreamService {
    private let api: APIClient
    private let notifications: NotificationManager?
    private let refresh: RefreshCoordinator?
    private let reconnectDelaySeconds: Double
    private let pumpWindowSeconds: Int

    private var running = false
    private var loopTask: Task<Void, Never>?
    private var subscriptionId: String?

    public init(api: APIClient,
                notifications: NotificationManager? = nil,
                refresh: RefreshCoordinator? = nil,
                reconnectDelaySeconds: Double = 3,
                pumpWindowSeconds: Int = 20) {
        self.api = api
        self.notifications = notifications
        self.refresh = refresh
        self.reconnectDelaySeconds = reconnectDelaySeconds
        self.pumpWindowSeconds = pumpWindowSeconds
    }

    /// Start the stream. Idempotent: a running stream is left alone.
    public func start() {
        guard !running else { return }
        running = true
        loopTask = Task { await self.runLoop() }
    }

    /// Stop the stream and untail (best effort) the live subscription.
    public func stop() async {
        running = false
        loopTask?.cancel()
        loopTask = nil
        if let sub = subscriptionId {
            subscriptionId = nil
            _ = try? await api.untailEvents(subscriptionId: sub)
        }
    }

    private func runLoop() async {
        while running && !Task.isCancelled {
            do {
                // Drop a stale subscription's local handler BEFORE re-tailing.
                // untailEvents removes the handler even when the RPC itself
                // fails, so events are never delivered twice after a reconnect.
                if let stale = subscriptionId {
                    subscriptionId = nil
                    _ = try? await api.untailEvents(subscriptionId: stale)
                }
                let sub = try await api.tailEvents(deviceId: nil, kinds: nil, severity: nil) {
                    [weak self] event in
                    guard let self else { return }
                    Task { await self.dispatch(event) }
                }
                subscriptionId = sub.subscriptionId

                guard let live = api as? LiveAPIClient else {
                    // Test/fake clients deliver pushes synchronously through the
                    // registered handler; there is no connection to pump.
                    return
                }
                // Pump until the connection dies (pumpEvents throws) or we stop.
                while running && !Task.isCancelled {
                    try await live.pumpEvents(waitSeconds: pumpWindowSeconds)
                }
            } catch {
                guard running, !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(reconnectDelaySeconds * 1_000_000_000))
            }
        }
    }

    private func dispatch(_ event: EventDTO) async {
        if let notifications {
            await notifications.handle(event)
        }
        if let refresh {
            await MainActor.run { refresh.signal() }
        }
    }
}
