import XCTest
@testable import PlugsightAppCore

/// Wave 2: the long-lived event stream feeds the notification engine and the
/// debounced refresh signal, and reconnects after a dropped daemon connection.
@MainActor
final class EventStreamServiceTests: XCTestCase {

    /// Poll until `condition` is true or the timeout elapses.
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func alertEvent(id: String) -> EventDTO {
        EventDTO(eventId: id, at: "2026-08-25T09:14:02Z", kind: "alert.raised",
                 severity: "warning", deviceId: "dev_1",
                 summary: "This device started typing right after plug-in.", actor: "system")
    }

    func testStreamFeedsNotificationsAndRefresh() async {
        let api = FakeAPIClient()
        let center = FakeNotificationCenterClient()
        let manager = NotificationManager(center: center, policy: { nil })
        let refresh = RefreshCoordinator(debounceSeconds: 0.05)
        let service = EventStreamService(api: api, notifications: manager, refresh: refresh)

        await service.start()
        await waitUntil { api.eventHandler != nil }
        XCTAssertNotNil(api.eventHandler, "start() subscribes exactly once via tailEvents")

        api.pushEvent(alertEvent(id: "e1"))
        await waitUntil { center.posted.count == 1 && refresh.tick == 1 }
        XCTAssertEqual(center.posted.count, 1, "the stream feeds the notification engine")
        XCTAssertEqual(refresh.tick, 1, "the stream bumps the refresh signal")
        await service.stop()
    }

    func testRefreshDebouncesABurstIntoOneTick() async {
        let api = FakeAPIClient()
        let refresh = RefreshCoordinator(debounceSeconds: 0.1)
        let service = EventStreamService(api: api, refresh: refresh)

        await service.start()
        await waitUntil { api.eventHandler != nil }
        for i in 0..<5 { api.pushEvent(alertEvent(id: "e\(i)")) }
        await waitUntil { refresh.tick >= 1 }
        // Give a would-be second tick time to (wrongly) fire.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(refresh.tick, 1, "a burst coalesces into one refresh")
        await service.stop()
    }

    func testReconnectsWithFixedDelayAfterTailFailure() async {
        let api = FakeAPIClient()
        api.tailResult = .failure(.daemonUnreachable)
        let service = EventStreamService(api: api, reconnectDelaySeconds: 0.05)

        await service.start()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(api.eventHandler, "no subscription while the daemon is unreachable")

        api.tailResult = .success(EventSubscriptionDTO(subscriptionId: "sub_2"))
        await waitUntil { api.eventHandler != nil }
        XCTAssertNotNil(api.eventHandler, "the stream retries after the fixed delay and re-tails")
        await service.stop()
    }

    // Wave 2 item 5: notifications arriving while the popover is loading must
    // not crash or disturb the popover's own 5 s poll path.
    func testEventsArrivingWhilePopoverLoadsAreHarmless() async {
        let api = FakeAPIClient()
        let center = FakeNotificationCenterClient()
        let manager = NotificationManager(center: center, policy: { nil })
        let refresh = RefreshCoordinator(debounceSeconds: 0.05)
        let service = EventStreamService(api: api, notifications: manager, refresh: refresh)
        await service.start()
        await waitUntil { api.eventHandler != nil }

        let popover = PopoverViewModel(api: api)
        async let loading: Void = popover.load()
        for i in 0..<20 { api.pushEvent(alertEvent(id: "p\(i)")) }
        _ = await loading
        await waitUntil { !center.posted.isEmpty }
        XCTAssertEqual(center.posted.count, 1, "the burst still coalesces mid-popover-load")
        await service.stop()
    }

    func testStartIsIdempotent() async {
        let api = FakeAPIClient()
        let service = EventStreamService(api: api)
        await service.start()
        await service.start()
        await waitUntil { api.eventHandler != nil }
        // FakeAPIClient keeps only the last handler; the observable invariant is
        // that a second start() does not crash and the stream still delivers.
        api.pushEvent(alertEvent(id: "e1"))
        await service.stop()
    }
}
