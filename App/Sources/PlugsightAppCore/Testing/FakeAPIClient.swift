// FakeAPIClient.swift
//
// A canned APIClient for tests and the snapshot generator. It returns fixed
// payloads (built to match 03's shapes) or throws a configured APIError, so
// every 04 surface state is reachable WITHOUT a running daemon. Tests set the
// stored results/errors before driving a view model; the snapshot generator
// seeds it with normal and at-scale data.
//
// Lives in AppCore (not the test target) deliberately: the visual snapshot tool
// in the App executable needs the same canned data the unit tests assert on, so
// the pictures and the tests describe ONE fixture.

import Foundation

/// A fully scriptable APIClient. Each result is either a value or an APIError.
public final class FakeAPIClient: APIClient, @unchecked Sendable {

    // Reads
    public var statusResult: Result<StatusDTO, APIError>
    public var devicesResult: Result<DeviceListDTO, APIError>
    public var deviceResult: Result<DeviceDetailDTO, APIError>
    public var timelineResult: Result<TimelineDTO, APIError>
    public var explainResult: Result<EventExplanationDTO, APIError>
    public var scoreResult: Result<ScoreDTO, APIError>
    public var alertsResult: Result<AlertListDTO, APIError>
    public var scansResult: Result<ScanListDTO, APIError>
    /// scan.get: the full record (verdicts + quarantine) for any scanId asked.
    public var scanDetailResult: Result<ScanDTO, APIError> = .success(Canned.scanInfected)
    public var policyResult: Result<PolicyDTO, APIError>
    public var tailResult: Result<EventSubscriptionDTO, APIError>
    public var untailResult: Result<Bool, APIError>
    /// The last live-event handler registered via tailEvents; `pushEvent` fires it.
    public private(set) var eventHandler: (@Sendable (EventDTO) -> Void)?

    // Writes
    public var setTrustResult: Result<DeviceDetailDTO, APIError>
    public var ackResult: Result<AlertDTO, APIError>
    public var scanStorageResult: Result<ScanStartedDTO, APIError>
    public var cancelScanResult: Result<ScanDTO, APIError>
    public var restoreResult: Result<QuarantineRestoreResultDTO, APIError>
    public var setPolicyResult: Result<PolicyDTO, APIError>
    public var installScannerResult: Result<ScannerInstallResult, APIError> = .success(ScannerInstallResult(accepted: true, reason: nil))

    // Spy fields — the last write arguments, for attribution/behaviour assertions.
    public private(set) var lastTrust: (deviceId: String, tier: String, note: String?)?
    public private(set) var lastScanStorageDeviceId: String?
    public private(set) var lastCancelScanId: String?
    public private(set) var lastRestore: (quarantineId: String, confirm: Bool)?
    public private(set) var lastAckAlertId: String?
    public private(set) var lastPolicy: (scanOnMount: Bool?, holdNewDrives: Bool?, threshold: String?,
                                         notifyUnsafe: Bool?, notifyNewDevice: Bool?, confirm: Bool)?

    public init(
        status: Result<StatusDTO, APIError> = .success(Canned.statusActive),
        devices: Result<DeviceListDTO, APIError> = .success(Canned.devicesNormal),
        device: Result<DeviceDetailDTO, APIError> = .success(Canned.deviceKeyboard),
        timeline: Result<TimelineDTO, APIError> = .success(Canned.timelineNormal),
        explain: Result<EventExplanationDTO, APIError> = .success(Canned.explanation),
        score: Result<ScoreDTO, APIError> = .success(Canned.scoreElevated),
        alerts: Result<AlertListDTO, APIError> = .success(Canned.alertsOne),
        scans: Result<ScanListDTO, APIError> = .success(Canned.scansClean),
        policy: Result<PolicyDTO, APIError> = .success(Canned.policyDefault),
        tail: Result<EventSubscriptionDTO, APIError> = .success(EventSubscriptionDTO(subscriptionId: "sub_1"))
    ) {
        self.statusResult = status
        self.devicesResult = devices
        self.deviceResult = device
        self.timelineResult = timeline
        self.explainResult = explain
        self.scoreResult = score
        self.alertsResult = alerts
        self.scansResult = scans
        self.policyResult = policy
        self.tailResult = tail
        self.untailResult = .success(true)
        self.setTrustResult = device
        self.ackResult = .success(Canned.alertAcknowledged)
        self.scanStorageResult = .success(Canned.scanStarted)
        self.cancelScanResult = .success(Canned.scanCanceled)
        self.restoreResult = .success(Canned.quarantineRestored)
        self.setPolicyResult = policy
    }

    private func value<T>(_ r: Result<T, APIError>) throws -> T {
        switch r { case .success(let v): return v; case .failure(let e): throw e }
    }

    public func getStatus() async throws -> StatusDTO { try value(statusResult) }
    public func listDevices(present: Bool?, trust: String?, cursor: String?) async throws -> DeviceListDTO { try value(devicesResult) }
    public func getDevice(id: String) async throws -> DeviceDetailDTO { try value(deviceResult) }
    public func getTimeline(deviceId: String?, kinds: [String]?, severity: String?, cursor: String?) async throws -> TimelineDTO { try value(timelineResult) }
    public func explainEvent(id: String) async throws -> EventExplanationDTO { try value(explainResult) }
    public func scoreDevice(id: String) async throws -> ScoreDTO { try value(scoreResult) }
    public func listAlerts(state: String?, deviceId: String?, cursor: String?) async throws -> AlertListDTO { try value(alertsResult) }
    public func getScans(deviceId: String) async throws -> ScanListDTO { try value(scansResult) }
    public func getScan(id: String) async throws -> ScanDTO { try value(scanDetailResult) }
    public func getPolicy() async throws -> PolicyDTO { try value(policyResult) }
    public func tailEvents(deviceId: String?, kinds: [String]?, severity: String?,
                           onEvent: @escaping @Sendable (EventDTO) -> Void) async throws -> EventSubscriptionDTO {
        // Match LiveAPIClient: the handler registers only when the tail succeeds.
        let sub = try value(tailResult)
        eventHandler = onEvent
        return sub
    }
    public func untailEvents(subscriptionId: String) async throws -> Bool { try value(untailResult) }
    /// Test helper: simulate a daemon `event.appended` push to the tail handler.
    public func pushEvent(_ event: EventDTO) { eventHandler?(event) }

    public func setTrust(deviceId: String, tier: String, note: String?) async throws -> DeviceDetailDTO {
        lastTrust = (deviceId, tier, note)
        return try value(setTrustResult)
    }
    public func acknowledgeAlert(alertId: String, comment: String?) async throws -> AlertDTO {
        lastAckAlertId = alertId
        return try value(ackResult)
    }
    public func scanStorage(deviceId: String) async throws -> ScanStartedDTO {
        lastScanStorageDeviceId = deviceId
        return try value(scanStorageResult)
    }
    public func cancelScan(scanId: String) async throws -> ScanDTO {
        lastCancelScanId = scanId
        return try value(cancelScanResult)
    }
    public func restoreQuarantine(quarantineId: String, confirm: Bool) async throws -> QuarantineRestoreResultDTO {
        lastRestore = (quarantineId, confirm)
        return try value(restoreResult)
    }
    public func setPolicy(scanOnMount: Bool?, holdNewDrives: Bool?, notificationThreshold: String?,
                          notifyUnsafe: Bool?, notifyNewDevice: Bool?, confirm: Bool) async throws -> PolicyDTO {
        lastPolicy = (scanOnMount, holdNewDrives, notificationThreshold, notifyUnsafe, notifyNewDevice, confirm)
        return try value(setPolicyResult)
    }
    /// Spy: set true once installScanner() has been called (WP2 onboarding tests).
    public private(set) var installScannerCalled = false
    public func installScanner() async throws -> ScannerInstallResult {
        installScannerCalled = true
        return try value(installScannerResult)
    }
}
