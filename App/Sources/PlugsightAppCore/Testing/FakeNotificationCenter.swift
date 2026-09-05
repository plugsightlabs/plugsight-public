// FakeNotificationCenter.swift
//
// A scriptable NotificationCenterClient for tests: records every posted
// notification and every authorization request, and lets a test set the
// authorization state directly. Lives in AppCore beside FakeAPIClient so the
// unit tests and any preview tooling share one fixture.

import Foundation

public final class FakeNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: NotificationAuthorization
    private var _grantOnRequest: Bool
    private var _requestCount = 0
    private var _posted: [AppNotification] = []

    public init(status: NotificationAuthorization = .notDetermined, grantOnRequest: Bool = true) {
        _status = status
        _grantOnRequest = grantOnRequest
    }

    public var status: NotificationAuthorization {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); defer { lock.unlock() }; _status = newValue }
    }
    /// How many times authorization was requested (must stay at 1 per install).
    public var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }
    /// Every notification posted, in order.
    public var posted: [AppNotification] { lock.lock(); defer { lock.unlock() }; return _posted }

    public func authorizationStatus() async -> NotificationAuthorization { status }

    public func requestAuthorization() async -> Bool {
        lock.lock(); defer { lock.unlock() }
        _requestCount += 1
        _status = _grantOnRequest ? .authorized : .denied
        return _grantOnRequest
    }

    public func post(_ notification: AppNotification) async {
        lock.lock(); defer { lock.unlock() }
        _posted.append(notification)
    }
}
