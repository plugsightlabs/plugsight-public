// NotificationManager.swift
//
// The app-side notification engine (04 notification model). It turns the live
// event stream into user notifications:
//
//   - `alert.raised` notifies while "Notify me when a device looks unsafe" is on
//     (notifyUnsafe; a nil policy key means ON, the default).
//   - `device.attached` notifies while "Also when any new device plugs in" is on
//     (notifyNewDevice; a nil policy key means OFF, the default).
//   - `scan.finished` NEVER notifies directly: an infected scan raises its own
//     `alert.raised`, which is the one notification. Mapping scan.finished too
//     would double-notify the same finding.
//
// Coalescing (04 S1c): at most one notification per device per five minutes,
// EXCEPT a critical-severity alert always breaks through, so a chatty device
// cannot bury a real warning and a real warning is never delayed.
//
// The OS notification center sits behind NotificationCenterClient so unit tests
// drive the trigger and coalescing logic with a fake center and a fake clock.
// The live wrapper (SystemNotificationCenterClient) asks for .alert + .sound
// explicitly (never provisional), once, only while authorization is undetermined.

import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// The app's view of notification authorization, readable by the Settings UI.
public enum NotificationAuthorization: String, Equatable, Sendable {
    case notDetermined, authorized, denied
}

/// One notification as the app posts it. Identifier and thread key the device,
/// so banners for the same device group together and replace sanely.
public struct AppNotification: Equatable, Sendable {
    public let identifier: String
    public let threadId: String
    public let title: String
    public let body: String
    public init(identifier: String, threadId: String, title: String, body: String) {
        self.identifier = identifier
        self.threadId = threadId
        self.title = title
        self.body = body
    }
}

/// The seam to the OS notification center. Tests inject a fake.
public protocol NotificationCenterClient: Sendable {
    func authorizationStatus() async -> NotificationAuthorization
    /// Explicit .alert + .sound request (no provisional). Returns granted.
    func requestAuthorization() async -> Bool
    func post(_ notification: AppNotification) async
}

/// The engine. An actor: events arrive from the stream service's tasks, the
/// Settings surface reads authorization, and the coalescing table is shared state.
public actor NotificationManager {
    /// 04: at most one notification per device per five minutes.
    public static let coalescingWindowSeconds: TimeInterval = 300

    private let center: NotificationCenterClient
    private let policy: @Sendable () async -> PolicyDTO?
    private let deviceName: @Sendable (String) async -> String?
    private let now: @Sendable () -> Date
    /// Last post time per coalescing key (deviceId, or a shared bucket for
    /// events that carry none).
    private var lastPostedAt: [String: Date] = [:]

    public init(center: NotificationCenterClient,
                policy: @escaping @Sendable () async -> PolicyDTO?,
                deviceName: @escaping @Sendable (String) async -> String? = { _ in nil },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.center = center
        self.policy = policy
        self.deviceName = deviceName
        self.now = now
    }

    /// Ask once at app start: an explicit .alert + .sound request, only while the
    /// user has never answered. A denied answer is respected, never re-prompted.
    public func requestAuthorizationIfNeeded() async {
        if await center.authorizationStatus() == .notDetermined {
            _ = await center.requestAuthorization()
        }
    }

    /// The current authorization, for the Settings degraded-state surface.
    public func authorization() async -> NotificationAuthorization {
        await center.authorizationStatus()
    }

    /// Feed one live event. Posts at most one notification, applying the policy
    /// gates and the per-device coalescing window.
    public func handle(_ event: EventDTO) async {
        switch event.kind {
        case "alert.raised":
            let p = await policy()
            guard p?.notifyUnsafe ?? true else { return }   // nil means ON (default)
        case "device.attached":
            let p = await policy()
            guard p?.notifyNewDevice ?? false else { return }  // nil means OFF (default)
        default:
            // scan.finished with an infected outcome arrives as its own
            // alert.raised; notifying here too would double-notify. Everything
            // else (detach, score ticks, daemon lifecycle) never notifies.
            return
        }

        let key = event.deviceId ?? "no-device"
        let critical = event.kind == "alert.raised" && event.severity == "critical"
        if !critical, let last = lastPostedAt[key],
           now().timeIntervalSince(last) < Self.coalescingWindowSeconds {
            return
        }
        lastPostedAt[key] = now()

        var title = "USB device"
        if let id = event.deviceId, let name = await deviceName(id), !name.isEmpty {
            title = name
        }
        await center.post(AppNotification(
            identifier: key, threadId: key, title: title, body: event.summary))
    }
}

/// A center that does nothing: the fallback for unbundled dev builds where the
/// OS center is unavailable. Reports notDetermined and never posts.
public final class NoopNotificationCenterClient: NotificationCenterClient {
    public init() {}
    public func authorizationStatus() async -> NotificationAuthorization { .notDetermined }
    public func requestAuthorization() async -> Bool { false }
    public func post(_ notification: AppNotification) async {}
}

#if canImport(UserNotifications)
/// The live wrapper over UNUserNotificationCenter.
public final class SystemNotificationCenterClient: NotificationCenterClient {
    /// UNUserNotificationCenter requires a real app bundle; a bare `swift run`
    /// binary has none and `.current()` would raise. Fail the init instead so
    /// the caller falls back to the no-op center.
    public init?() {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
    }

    public func authorizationStatus() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func post(_ notification: AppNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadId
        content.sound = .default
        // No actions or buttons (owner decision Q3, 09).
        let request = UNNotificationRequest(
            identifier: notification.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
