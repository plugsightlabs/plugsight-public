// LiveAPIClient.swift
//
// The real API client. It speaks the daemon's newline-framed JSON-RPC 2.0 over a
// Unix domain socket (02), performs `auth.hello` as the first message on the
// connection with the token from ~/Library/Application Support/Plugsight/, and
// correlates responses by id. `tailEvents` uses the daemon's SUBSCRIPTION model
// (02): events.tail returns a subscriptionId, then the daemon pushes
// `event.appended` notifications on the same connection, routed to onEvent.
//
// Transport is the reusable, testable-by-inspection part. The per-method response
// mapping decodes the daemon `result` into the same DTOs the view models consume;
// exact field parity with the daemon is an INTEGRATION-verification step (it
// needs a running daemon, which the unit tests deliberately do not require).
//
// A missing socket / refused connection surfaces as APIError.daemonUnreachable so
// the whole UI recovers with the literal fix (9b).

import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public actor LiveAPIClient: APIClient {

    public struct ClientInfo: Sendable {
        public let name: String
        public let kind: String   // "ui"
        public init(name: String = "plugsight-app", kind: String = "ui") {
            self.name = name; self.kind = kind
        }
    }

    private let stateDirectory: String
    private let clientInfo: ClientInfo
    private var connection: UDSConnection?
    private var nextId = 1
    /// Live-event handlers keyed by subscriptionId (02 subscription model). Fired
    /// for every `event.appended` push until the subscription is untailed.
    private var eventHandlers: [String: @Sendable (EventDTO) -> Void] = [:]

    public init(stateDirectory: String? = nil, clientInfo: ClientInfo = ClientInfo()) {
        self.stateDirectory = stateDirectory
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Plugsight")
        self.clientInfo = clientInfo
    }

    private var socketPath: String { (stateDirectory as NSString).appendingPathComponent("plugsightd.sock") }
    private var tokenPath: String { (stateDirectory as NSString).appendingPathComponent("api-token") }

    // MARK: - Connection lifecycle

    private func ensureConnected() async throws -> UDSConnection {
        if let c = connection, c.isOpen { return c }
        guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw APIError.daemonUnreachable
        }
        let conn: UDSConnection
        do {
            conn = try UDSConnection(path: socketPath)
        } catch {
            throw APIError.daemonUnreachable
        }
        // auth.hello MUST be the first message on the connection (02).
        let hello: [String: Any] = [
            "token": token,
            "clientInfo": ["name": clientInfo.name, "kind": clientInfo.kind],
        ]
        _ = try await rawCall(on: conn, method: "auth.hello", params: hello, waitSeconds: 5)
        connection = conn
        return conn
    }

    /// Send one request line and read response lines until the matching id.
    private func rawCall(on conn: UDSConnection, method: String,
                         params: Any?, waitSeconds: Int) async throws -> Any {
        let id = nextId; nextId += 1
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { body["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: body)
        try conn.writeLine(data)

        // Read lines until the one carrying our id. Unsolicited `event.appended`
        // notifications (no id) that arrive meanwhile are routed to the live-event
        // handlers, NOT dropped (02 subscription model).
        let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
        while Date() < deadline {
            guard let line = try conn.readLine(deadline: deadline) else { break }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if obj["id"] == nil, (obj["method"] as? String) == "event.appended" {
                dispatchAppended(obj["params"])
                continue
            }
            if let rid = obj["id"] as? Int, rid == id {
                if let err = obj["error"] as? [String: Any] {
                    throw Self.mapError(err)
                }
                return obj["result"] ?? [:]
            }
        }
        throw APIError.daemonUnreachable
    }

    /// Decode an `event.appended` notification payload as an EventDTO and deliver
    /// it to every registered live-event handler.
    private func dispatchAppended(_ params: Any?) {
        guard let params,
              let data = try? JSONSerialization.data(withJSONObject: params),
              let event = try? JSONDecoder().decode(EventDTO.self, from: data) else { return }
        for handler in eventHandlers.values { handler(event) }
    }

    /// Read the connection for up to `waitSeconds`, delivering any `event.appended`
    /// pushes to the registered handlers. A persistent tail consumer loops on this.
    public func pumpEvents(waitSeconds: Int) async throws {
        let conn = try await ensureConnected()
        let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
        while Date() < deadline {
            guard let line = try? conn.readLine(deadline: deadline) else { break }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if obj["id"] == nil, (obj["method"] as? String) == "event.appended" {
                dispatchAppended(obj["params"])
            }
        }
    }

    /// Public typed call: returns the `result` decoded into `T`.
    private func call<T: Decodable>(_ type: T.Type, method: String,
                                    params: Any? = nil, waitSeconds: Int = 20) async throws -> T {
        let conn = try await ensureConnected()
        do {
            let result = try await rawCall(on: conn, method: method, params: params, waitSeconds: waitSeconds)
            let data = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(T.self, from: data)
        } catch let e as APIError {
            throw e
        } catch {
            // A transport/decoding failure after connect is reported honestly.
            connection = nil
            throw APIError(kind: .transport, message: "The app couldn’t read the daemon’s reply.")
        }
    }

    private static func mapError(_ err: [String: Any]) -> APIError {
        let message = (err["message"] as? String) ?? "The daemon reported an error."
        let kindStr = ((err["data"] as? [String: Any])?["kind"] as? String) ?? "transport"
        let kind = APIError.Kind(rawValue: kindStr) ?? .transport
        return APIError(kind: kind, message: message)
    }

    // MARK: - APIClient (reads)

    public func getStatus() async throws -> StatusDTO {
        try await call(StatusDTO.self, method: "status.get")
    }
    public func listDevices(present: Bool?, trust: String?, cursor: String?) async throws -> DeviceListDTO {
        var p: [String: Any] = [:]
        if let present { p["present"] = present }
        if let trust { p["trust"] = trust }
        if let cursor { p["cursor"] = cursor }
        return try await call(DeviceListDTO.self, method: "devices.list", params: p)
    }
    public func getDevice(id: String) async throws -> DeviceDetailDTO {
        try await call(DeviceDetailDTO.self, method: "devices.get", params: ["deviceId": id])
    }
    public func getTimeline(deviceId: String?, kinds: [String]?, severity: String?, cursor: String?) async throws -> TimelineDTO {
        var p: [String: Any] = [:]
        if let deviceId { p["deviceId"] = deviceId }
        if let kinds { p["kinds"] = kinds }
        if let severity { p["severity"] = severity }
        if let cursor { p["cursor"] = cursor }
        return try await call(TimelineDTO.self, method: "timeline.list", params: p)
    }
    public func explainEvent(id: String) async throws -> EventExplanationDTO {
        try await call(EventExplanationDTO.self, method: "events.get", params: ["eventId": id])
    }
    public func scoreDevice(id: String) async throws -> ScoreDTO {
        try await call(ScoreDTO.self, method: "score.get", params: ["deviceId": id])
    }
    public func listAlerts(state: String?, deviceId: String?, cursor: String?) async throws -> AlertListDTO {
        var p: [String: Any] = [:]
        if let state { p["state"] = state }
        if let deviceId { p["deviceId"] = deviceId }
        if let cursor { p["cursor"] = cursor }
        return try await call(AlertListDTO.self, method: "alerts.list", params: p)
    }
    public func getScans(deviceId: String) async throws -> ScanListDTO {
        try await call(ScanListDTO.self, method: "scans.list", params: ["deviceId": deviceId])
    }
    public func getPolicy() async throws -> PolicyDTO {
        try await call(PolicyDTO.self, method: "policy.get")
    }
    public func tailEvents(deviceId: String?, kinds: [String]?, severity: String?,
                           onEvent: @escaping @Sendable (EventDTO) -> Void) async throws -> EventSubscriptionDTO {
        var filter: [String: Any] = [:]
        if let deviceId { filter["deviceId"] = deviceId }
        if let kinds { filter["kinds"] = kinds }
        if let severity { filter["severity"] = severity }
        var p: [String: Any] = [:]
        if !filter.isEmpty { p["filter"] = filter }
        // events.tail returns the subscription id; event.appended notifications
        // deliver EventDTOs to `onEvent` thereafter (routed by the read loop).
        let sub = try await call(EventSubscriptionDTO.self, method: "events.tail", params: p)
        eventHandlers[sub.subscriptionId] = onEvent
        return sub
    }

    public func untailEvents(subscriptionId: String) async throws -> Bool {
        eventHandlers[subscriptionId] = nil
        let r = try await call(UntailResultDTO.self, method: "events.untail",
                               params: ["subscriptionId": subscriptionId])
        return r.ok
    }

    // MARK: - APIClient (writes)

    public func setTrust(deviceId: String, tier: String, note: String?) async throws -> DeviceDetailDTO {
        var p: [String: Any] = ["deviceId": deviceId, "tier": tier]
        if let note { p["note"] = note }
        return try await call(DeviceDetailDTO.self, method: "trust.set", params: p)
    }
    public func acknowledgeAlert(alertId: String, comment: String?) async throws -> AlertDTO {
        var p: [String: Any] = ["alertId": alertId]
        if let comment { p["comment"] = comment }
        return try await call(AlertDTO.self, method: "alerts.ack", params: p)
    }
    public func scanStorage(deviceId: String) async throws -> ScanStartedDTO {
        try await call(ScanStartedDTO.self, method: "scan.start", params: ["deviceId": deviceId])
    }
    public func cancelScan(scanId: String) async throws -> ScanDTO {
        try await call(ScanDTO.self, method: "scan.cancel", params: ["scanId": scanId])
    }
    public func restoreQuarantine(quarantineId: String, confirm: Bool) async throws -> QuarantineRestoreResultDTO {
        try await call(QuarantineRestoreResultDTO.self, method: "quarantine.restore",
                       params: ["quarantineId": quarantineId, "confirm": confirm])
    }
    public func setPolicy(scanOnMount: Bool?, holdNewDrives: Bool?, notificationThreshold: String?, confirm: Bool) async throws -> PolicyDTO {
        var p: [String: Any] = ["confirm": confirm]
        if let scanOnMount { p["scanOnMount"] = scanOnMount }
        if let holdNewDrives { p["holdUntilScanned"] = holdNewDrives }
        if let notificationThreshold { p["notificationThreshold"] = notificationThreshold }
        return try await call(PolicyDTO.self, method: "policy.set", params: p)
    }
    public func installScanner() async throws -> ScannerInstallResult {
        // scanner.install takes no params; the daemon accepts empty/absent params.
        try await call(ScannerInstallResult.self, method: "scanner.install", params: [:])
    }
}
