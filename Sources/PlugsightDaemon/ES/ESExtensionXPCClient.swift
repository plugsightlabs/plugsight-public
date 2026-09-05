// ESExtensionXPCClient.swift
//
// The daemon's side of the daemon<->extension XPC link (02): connect to the
// Mach service the ES system extension publishes, push ESWire-encoded policy
// snapshots, and receive the extension's observed events on the same
// connection. This client is DELIBERATELY tolerant: the extension being
// absent, unapproved, or crashed is a NORMAL state (the entitlement is
// owner-gated and may simply not exist yet), so every failure path degrades
// to "not connected" and the mount decision fails open on the extension side
// by cache staleness. Nothing here ever blocks the daemon's boot.
//
// Live-handshake truth (status.get): `handshakeActive` is true only while the
// LAST policy push was acknowledged by the extension recently (within the
// policy TTL). No acknowledged push, no "active" — a half-open connection or
// a wedged extension reads as inactive, which is the honest answer.

import Foundation
import PlugsightESCore

/// Where the client connects. Production uses the privileged Mach service;
/// tests hand an anonymous in-process listener endpoint.
public enum ESExtensionEndpoint {
    case machService(name: String)
    case listenerEndpoint(NSXPCListenerEndpoint)
}

public final class ESExtensionXPCClient: NSObject, ESDaemonEventSinkProtocol, @unchecked Sendable {

    /// Decoded events from the extension. Set before `connect()`.
    public var onEvent: (@Sendable (ESObservedEvent) -> Void)?
    /// Fired on every (re)connection, so the pusher can push a fresh snapshot
    /// immediately instead of waiting for the next heartbeat.
    public var onConnect: (@Sendable () -> Void)?

    private let endpoint: ESExtensionEndpoint
    /// Code-signing requirement string the extension peer must satisfy
    /// (ESPeerRequirement.codeSigningRequirementString for the extension's
    /// bundle id). nil skips the check (in-process test listeners are not
    /// signed as the extension). BOTH sides validate the peer (02); the
    /// extension's listener enforces its own half.
    private let peerRequirement: String?
    private let ackTTL: TimeInterval
    private let reconnectDelay: TimeInterval
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var lastAckAt: Date?
    private var stopped = false

    /// - Parameters:
    ///   - endpoint: production `.machService(ESDefaults.machServiceName)`.
    ///   - ackTTL: how recent the last acknowledged push must be for the
    ///     handshake to count as live (defaults to the policy TTL).
    ///   - reconnectDelay: pause before redialing after interruption or
    ///     invalidation. The extension may legitimately never exist.
    public init(
        endpoint: ESExtensionEndpoint,
        peerRequirement: String? = nil,
        ackTTL: TimeInterval = ESDefaults.policyTTL,
        reconnectDelay: TimeInterval = 5,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.peerRequirement = peerRequirement
        self.ackTTL = ackTTL
        self.reconnectDelay = reconnectDelay
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Dial the extension. Safe to call when it is absent: the connection
    /// simply invalidates and the client redials later.
    public func connect() {
        lock.lock()
        guard !stopped, connection == nil else { lock.unlock(); return }
        let conn = makeConnection()
        connection = conn
        lock.unlock()
        conn.resume()
        onConnect?()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.invalidate()
    }

    private func makeConnection() -> NSXPCConnection {
        let conn: NSXPCConnection
        switch endpoint {
        case .machService(let name):
            // The extension's service lives in the privileged bootstrap.
            conn = NSXPCConnection(machServiceName: name, options: .privileged)
        case .listenerEndpoint(let ep):
            conn = NSXPCConnection(listenerEndpoint: ep)
        }
        conn.remoteObjectInterface = NSXPCInterface(with: ESExtensionXPCProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: ESDaemonEventSinkProtocol.self)
        conn.exportedObject = self
        if let peerRequirement {
            // OS-evaluated on every message; an unsatisfiable requirement just
            // means no link (fail-open on the extension side, inactive here).
            conn.setCodeSigningRequirement(peerRequirement)
        }
        conn.interruptionHandler = { [weak self] in self?.dropAndRedial() }
        conn.invalidationHandler = { [weak self] in self?.dropAndRedial() }
        return conn
    }

    private func dropAndRedial() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lastAckAt = nil
        let shouldRedial = !stopped
        lock.unlock()
        guard shouldRedial else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - Policy push

    /// Push one snapshot. Failure is normal (extension absent): the error
    /// handler drops the connection and schedules a redial; the extension's
    /// cache goes stale and stale fails open.
    public func push(_ snapshot: ESPolicySnapshot) {
        let payload: Data
        do {
            payload = try ESWire.encode(snapshot)
        } catch {
            FileHandle.standardError.write(Data("plugsightd: ES policy encode error: \(error)\n".utf8))
            return
        }
        lock.lock()
        let conn = connection
        lock.unlock()
        guard let conn else { return }
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.dropAndRedial()
        }
        guard let remote = proxy as? ESExtensionXPCProtocol else { return }
        remote.pushPolicy(payload) { [weak self] accepted in
            guard let self, accepted else { return }
            self.lock.lock()
            self.lastAckAt = self.clock()
            self.lock.unlock()
        }
    }

    /// True only while the last acknowledged policy push is recent. THE
    /// signal status.get reports as endpoint-security "active" (unit 5): a
    /// dead, absent, or unapproved extension can never acknowledge, so it can
    /// never read as active.
    public var handshakeActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastAckAt else { return false }
        return clock().timeIntervalSince(lastAckAt) <= ackTTL
    }

    // MARK: - ESDaemonEventSinkProtocol (extension -> daemon)

    public func deliverEvent(_ payload: Data) {
        do {
            let event = try ESWire.decode(ESObservedEvent.self, from: payload)
            onEvent?(event)
        } catch {
            // Drop-and-log, mirroring the extension's tolerance of us.
            FileHandle.standardError.write(Data("plugsightd: undecodable ES event dropped: \(error)\n".utf8))
        }
    }
}
