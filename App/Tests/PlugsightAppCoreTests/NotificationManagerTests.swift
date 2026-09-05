import XCTest
@testable import PlugsightAppCore

/// Wave 2: the notification engine's trigger and coalescing logic, driven with a
/// fake center and a fake clock (04 notification model, S1a/S1c).
final class NotificationManagerTests: XCTestCase {

    /// A settable clock the manager reads through its `now` closure.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_000_000)
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return _now }
            set { lock.lock(); defer { lock.unlock() }; _now = newValue }
        }
        func advance(seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeManager(
        center: FakeNotificationCenterClient = FakeNotificationCenterClient(),
        policy: PolicyDTO? = nil,
        clock: Clock = Clock(),
        deviceName: @escaping @Sendable (String) async -> String? = { _ in "Kingston DataTraveler" }
    ) -> NotificationManager {
        NotificationManager(center: center,
                            policy: { policy },
                            deviceName: deviceName,
                            now: { clock.now })
    }

    private func alertEvent(id: String = "evt_1", deviceId: String? = "dev_1",
                            severity: String = "warning",
                            summary: String = "This device started typing right after plug-in.") -> EventDTO {
        EventDTO(eventId: id, at: "2026-08-25T09:14:02Z", kind: "alert.raised",
                 severity: severity, deviceId: deviceId, summary: summary, actor: "system")
    }

    private func attachEvent(id: String = "evt_a", deviceId: String = "dev_2") -> EventDTO {
        EventDTO(eventId: id, at: "2026-08-25T09:00:00Z", kind: "device.attached",
                 severity: "info", deviceId: deviceId, summary: "A new device plugged in.", actor: "system")
    }

    // MARK: - Authorization

    func testRequestsAuthorizationOnceWhileUndetermined() async {
        let center = FakeNotificationCenterClient(status: .notDetermined, grantOnRequest: true)
        let manager = makeManager(center: center)
        await manager.requestAuthorizationIfNeeded()
        await manager.requestAuthorizationIfNeeded()
        XCTAssertEqual(center.requestCount, 1, "asked exactly once; the answer is then respected")
        let auth = await manager.authorization()
        XCTAssertEqual(auth, .authorized)
    }

    func testDeniedIsNeverRePrompted() async {
        let center = FakeNotificationCenterClient(status: .denied)
        let manager = makeManager(center: center)
        await manager.requestAuthorizationIfNeeded()
        XCTAssertEqual(center.requestCount, 0, "a denied answer is respected, never re-prompted")
        let auth = await manager.authorization()
        XCTAssertEqual(auth, .denied)
    }

    // MARK: - Triggers

    func testAlertRaisedNotifiesByDefault() async {
        // No policy on the wire at all (older daemon): notifyUnsafe defaults ON.
        let center = FakeNotificationCenterClient()
        let manager = makeManager(center: center, policy: nil)
        await manager.handle(alertEvent())
        XCTAssertEqual(center.posted.count, 1)
        let n = center.posted[0]
        XCTAssertEqual(n.title, "Kingston DataTraveler", "title is the device name")
        XCTAssertEqual(n.body, "This device started typing right after plug-in.",
                       "body is the event's plain-language summary")
        XCTAssertEqual(n.identifier, "dev_1", "identifier keys the device")
        XCTAssertEqual(n.threadId, "dev_1", "thread groups per device")
    }

    func testNilNotifyUnsafeKeyMeansOn() async {
        let center = FakeNotificationCenterClient()
        let policy = PolicyDTO(scanOnMount: true, holdUntilScanned: false,
                               notificationThreshold: "warning")  // keys absent
        let manager = makeManager(center: center, policy: policy)
        await manager.handle(alertEvent())
        XCTAssertEqual(center.posted.count, 1)
    }

    func testAlertRaisedRespectsNotifyUnsafeOff() async {
        let center = FakeNotificationCenterClient()
        let policy = PolicyDTO(scanOnMount: true, holdUntilScanned: false,
                               notificationThreshold: "warning", notifyUnsafe: false)
        let manager = makeManager(center: center, policy: policy)
        await manager.handle(alertEvent())
        XCTAssertTrue(center.posted.isEmpty)
    }

    func testDeviceAttachedIsOffByDefault() async {
        let center = FakeNotificationCenterClient()
        let manager = makeManager(center: center, policy: nil)
        await manager.handle(attachEvent())
        XCTAssertTrue(center.posted.isEmpty, "notifyNewDevice defaults OFF")
    }

    func testDeviceAttachedNotifiesWhenEnabled() async {
        let center = FakeNotificationCenterClient()
        let policy = PolicyDTO(scanOnMount: true, holdUntilScanned: false,
                               notificationThreshold: "warning", notifyNewDevice: true)
        let manager = makeManager(center: center, policy: policy)
        await manager.handle(attachEvent())
        XCTAssertEqual(center.posted.count, 1)
    }

    func testScanFinishedNeverNotifiesDirectly() async {
        // An infected scan raises its own alert.raised; scan.finished mapping too
        // would double-notify the same finding.
        let center = FakeNotificationCenterClient()
        let policy = PolicyDTO(scanOnMount: true, holdUntilScanned: false,
                               notificationThreshold: "warning",
                               notifyUnsafe: true, notifyNewDevice: true)
        let manager = makeManager(center: center, policy: policy)
        let scan = EventDTO(eventId: "evt_s", at: "2026-08-25T09:20:00Z", kind: "scan.finished",
                            severity: "critical", deviceId: "dev_1",
                            summary: "Scan found an infected file.", actor: "system")
        await manager.handle(scan)
        XCTAssertTrue(center.posted.isEmpty)
    }

    func testUnknownDeviceNameFallsBackPlainly() async {
        let center = FakeNotificationCenterClient()
        let manager = makeManager(center: center, deviceName: { _ in nil })
        await manager.handle(alertEvent())
        XCTAssertEqual(center.posted.first?.title, "USB device")
    }

    // MARK: - Coalescing (04 S1c)

    func testCoalescesToOnePerDevicePerFiveMinutes() async {
        let center = FakeNotificationCenterClient()
        let clock = Clock()
        let manager = makeManager(center: center, clock: clock)
        await manager.handle(alertEvent(id: "e1"))
        clock.advance(seconds: 60)
        await manager.handle(alertEvent(id: "e2"))
        XCTAssertEqual(center.posted.count, 1, "second warning inside the window coalesces")
        clock.advance(seconds: 241)  // 301 s after the first post
        await manager.handle(alertEvent(id: "e3"))
        XCTAssertEqual(center.posted.count, 2, "the window is five minutes, then delivery resumes")
    }

    func testCoalescingIsPerDevice() async {
        let center = FakeNotificationCenterClient()
        let clock = Clock()
        let manager = makeManager(center: center, clock: clock)
        await manager.handle(alertEvent(id: "e1", deviceId: "dev_1"))
        await manager.handle(alertEvent(id: "e2", deviceId: "dev_9"))
        XCTAssertEqual(center.posted.count, 2, "a different device is never suppressed")
    }

    func testCriticalAlertBreaksThroughCoalescing() async {
        let center = FakeNotificationCenterClient()
        let clock = Clock()
        let manager = makeManager(center: center, clock: clock)
        await manager.handle(alertEvent(id: "e1", severity: "warning"))
        clock.advance(seconds: 10)
        await manager.handle(alertEvent(id: "e2", severity: "critical",
                                        summary: "This device is typing commands."))
        XCTAssertEqual(center.posted.count, 2, "critical always breaks through")
        XCTAssertEqual(center.posted.last?.body, "This device is typing commands.")
    }

    func testTenAlertBurstYieldsOneBanner() async {
        // S1c acceptance: a scripted 10-alert burst yields at most one device
        // banner inside the five-minute window.
        let center = FakeNotificationCenterClient()
        let clock = Clock()
        let manager = makeManager(center: center, clock: clock)
        for i in 0..<10 {
            await manager.handle(alertEvent(id: "e\(i)"))
            clock.advance(seconds: 5)
        }
        XCTAssertEqual(center.posted.count, 1)
    }
}
