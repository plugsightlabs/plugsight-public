// APIClient.swift
//
// The seam the view models test against. Both faces call the same local API
// (02); this protocol is the app-side view of it. Tests inject a FakeAPIClient
// returning canned payloads, so no live daemon is needed to exercise every
// surface state. The live implementation (LiveAPIClient) speaks the UDS
// newline-JSON-RPC framing.
//
// Error taxonomy mirrors 02/03: a stable `kind` plus the daemon's human-readable
// message and the literal recovery. `daemon_unreachable` in particular must be
// recoverable by a non-technical user from the message alone (9b).

import Foundation

/// The stable error kinds from 02/03, surfaced verbatim to the UI.
public struct APIError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case daemonUnreachable = "daemon_unreachable"
        case versionMismatch = "version_mismatch"
        case notFound = "not_found"
        case conflict
        case invalidParams = "invalid_params"
        case scannerUnavailable = "scanner_unavailable"
        case storeUnreadable = "store_unreadable"
        case transport
    }
    public let kind: Kind
    /// The daemon's human-readable message, untouched (03).
    public let message: String
    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// The canonical daemon-down error: message doubles as the recovery (9b).
    public static let daemonUnreachable = APIError(
        kind: .daemonUnreachable,
        message: "Plugsight isn’t running. Start Plugsight from your Applications folder, "
            + "or choose Start monitoring from its menu."
    )
}

/// The result of `events.tail` (02 SUBSCRIPTION model): the id of the live
/// subscription. The daemon then pushes `event.appended` JSON-RPC notifications
/// (each an `EventDTO`) on the SAME connection until `events.untail`. The app is a
/// persistent connection that receives pushes — it does NOT long-poll (the
/// long-poll bridge lives only in the agent-facing MCP tool, 03).
public struct EventSubscriptionDTO: Codable, Equatable, Sendable {
    public var subscriptionId: String
    public init(subscriptionId: String) { self.subscriptionId = subscriptionId }
}

/// The result of `events.untail`: whether the subscription was removed.
public struct UntailResultDTO: Codable, Equatable, Sendable {
    public var ok: Bool
    public init(ok: Bool) { self.ok = ok }
}

/// The result of `scanner.install` (app<->daemon RPC only): whether the install
/// was started, plus the reason it was not (an install already running, or
/// Homebrew not found). Progress is then polled via status.get's scanner
/// installState/installDetail.
public struct ScannerInstallResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var reason: String?
    public init(accepted: Bool, reason: String?) {
        self.accepted = accepted
        self.reason = reason
    }
}

/// The app-side view of the local API (02). Every method is async and throws
/// `APIError`. View models depend on this protocol, never on a socket.
public protocol APIClient: Sendable {
    // Reads
    func getStatus() async throws -> StatusDTO
    func listDevices(present: Bool?, trust: String?, cursor: String?) async throws -> DeviceListDTO
    func getDevice(id: String) async throws -> DeviceDetailDTO
    func getTimeline(deviceId: String?, kinds: [String]?, severity: String?, cursor: String?) async throws -> TimelineDTO
    func explainEvent(id: String) async throws -> EventExplanationDTO
    func scoreDevice(id: String) async throws -> ScoreDTO
    func listAlerts(state: String?, deviceId: String?, cursor: String?) async throws -> AlertListDTO
    func getScans(deviceId: String) async throws -> ScanListDTO
    func getPolicy() async throws -> PolicyDTO

    // Live event stream (02 subscription model): tail returns a subscriptionId and
    // registers `onEvent`, which fires for every `event.appended` push until
    // untail. Delivery is driven on the persistent connection, not a poll.
    func tailEvents(deviceId: String?, kinds: [String]?, severity: String?,
                    onEvent: @escaping @Sendable (EventDTO) -> Void) async throws -> EventSubscriptionDTO
    func untailEvents(subscriptionId: String) async throws -> Bool

    // Writes — return the updated object so callers can reflect it immediately.
    func setTrust(deviceId: String, tier: String, note: String?) async throws -> DeviceDetailDTO
    func acknowledgeAlert(alertId: String, comment: String?) async throws -> AlertDTO
    func scanStorage(deviceId: String) async throws -> ScanStartedDTO
    func cancelScan(scanId: String) async throws -> ScanDTO
    func restoreQuarantine(quarantineId: String, confirm: Bool) async throws -> QuarantineRestoreResultDTO
    func setPolicy(scanOnMount: Bool?, holdNewDrives: Bool?, notificationThreshold: String?, confirm: Bool) async throws -> PolicyDTO

    /// Start a one-click ClamAV install (onboarding scanner step). Returns whether
    /// it was accepted; progress is polled via `getStatus().scanner.installState`.
    func installScanner() async throws -> ScannerInstallResult
}
