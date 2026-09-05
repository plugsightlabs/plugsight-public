// ESXPCListener.swift
//
// The THIN XPC side (02): the extension publishes a Mach service (name fixed
// in its Info.plist); the daemon connects; BOTH sides validate the peer's
// code-signing requirement before exchanging anything. Enforcement is
// two-layered, deliberately:
//
//  1. NSXPCConnection.setCodeSigningRequirement(_:) — the OS evaluates the
//     requirement string (built by ESPeerRequirement) against the peer on
//     every message. This is the authoritative gate.
//  2. PeerValidator.validatePeer — the pure, unit-tested restatement, run at
//     accept time over SecCode-derived info. It exists so the policy is
//     readable and testable; disagreement between the layers rejects.
//
// Rejection here FAILS CLOSED (the opposite of the mount path): an
// unverified peer gets no listener endpoint, no policy, no events.

import Foundation
import os
import PlugsightESCore
import Security

// The XPC protocols (ESExtensionXPCProtocol / ESDaemonEventSinkProtocol) are
// declared in PlugsightESCore (ESXPCProtocols.swift) so the daemon's client
// compiles against the same definitions without importing this ES-linking
// target.

public final class ESXPCListener: NSObject, NSXPCListenerDelegate, ESExtensionXPCProtocol {
    private let log = Logger(subsystem: "com.plugsight.esext", category: "xpc")
    private let listener: NSXPCListener
    private let requirement: ESPeerRequirement
    /// Exact bundle id the connecting daemon must present (02's table).
    private let daemonBundleID: String
    private let cacheBox: ESPolicyCacheBox
    /// Accepted daemon connections, for extension -> daemon event forwarding.
    /// Guarded by `connectionsLock`; invalidated connections are pruned by
    /// their invalidation handler.
    private let connectionsLock = NSLock()
    private var daemonConnections: [NSXPCConnection] = []

    public init(
        requirement: ESPeerRequirement,
        daemonBundleID: String,
        cacheBox: ESPolicyCacheBox,
        machServiceName: String = ESDefaults.machServiceName
    ) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.requirement = requirement
        self.daemonBundleID = daemonBundleID
        self.cacheBox = cacheBox
        super.init()
        listener.delegate = self
    }

    public func resume() { listener.resume() }

    // MARK: - NSXPCListenerDelegate

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Layer 1: OS-enforced requirement, evaluated on every message.
        do {
            try connection.setCodeSigningRequirement(
                requirement.codeSigningRequirementString(exactBundleID: daemonBundleID)
            )
        } catch {
            log.error("rejecting peer: requirement rejected by the OS: \(error)")
            return false
        }

        // Layer 2: the pure, tested predicate over what the peer presents.
        // NOTE (checker): pid-keyed SecCode lookup is subject to pid reuse
        // (TOCTOU); it is the readable RESTATEMENT, not the primary gate —
        // layer 1 revalidates the requirement per message regardless.
        let presented = Self.presentedInfo(forPid: connection.processIdentifier)
        guard PeerValidator.validatePeer(requirement: requirement, presented: presented) else {
            log.error(
                "rejecting peer pid \(connection.processIdentifier): presented team=\(presented.teamID ?? "nil", privacy: .public) bundle=\(presented.bundleID ?? "nil", privacy: .public) valid=\(presented.signingValid)"
            )
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: ESExtensionXPCProtocol.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: ESDaemonEventSinkProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.connectionsLock.lock()
            self.daemonConnections.removeAll { $0 === connection }
            self.connectionsLock.unlock()
        }
        connectionsLock.lock()
        daemonConnections.append(connection)
        connectionsLock.unlock()
        connection.resume()
        log.log("accepted daemon connection pid \(connection.processIdentifier)")
        return true
    }

    // MARK: - Extension -> daemon event forwarding

    /// Forward one observed event to every connected daemon. Fire and forget:
    /// no daemon connected simply drops the event (the daemon's own record has
    /// the monitoring-gap story; the extension never buffers).
    public func forward(_ event: ESObservedEvent) {
        let payload: Data
        do {
            payload = try ESWire.encode(event)
        } catch {
            log.error("could not encode observed event for forwarding: \(error)")
            return
        }
        connectionsLock.lock()
        let connections = daemonConnections
        connectionsLock.unlock()
        for connection in connections {
            let proxy = connection.remoteObjectProxyWithErrorHandler { [log] error in
                log.error("event forward failed: \(error)")
            }
            (proxy as? ESDaemonEventSinkProtocol)?.deliverEvent(payload)
        }
    }

    // MARK: - ESExtensionXPCProtocol

    public func pushPolicy(_ payload: Data, acknowledgement: @escaping (Bool) -> Void) {
        do {
            let snapshot = try ESWire.decode(ESPolicySnapshot.self, from: payload)
            cacheBox.update(snapshot)
            log.log("policy snapshot updated (hold=\(snapshot.holdUntilScanned), \(snapshot.trustByDeviceKey.count) devices)")
            acknowledgement(true)
        } catch {
            // Drop-and-log: a bad payload leaves the cache stale, and stale
            // fails open. Never crash the extension over daemon input.
            log.error("dropping undecodable policy payload: \(error)")
            acknowledgement(false)
        }
    }

    // MARK: - SecCode extraction for the layer-2 restatement

    static func presentedInfo(forPid pid: pid_t) -> ESPresentedPeerInfo {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else {
            return ESPresentedPeerInfo(teamID: nil, bundleID: nil, signingValid: false)
        }
        let signingValid = SecCodeCheckValidity(code, [], nil) == errSecSuccess

        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
              ) == errSecSuccess,
              let dict = info as? [CFString: Any] else {
            return ESPresentedPeerInfo(teamID: nil, bundleID: nil, signingValid: signingValid)
        }
        return ESPresentedPeerInfo(
            teamID: dict[kSecCodeInfoTeamIdentifier] as? String,
            bundleID: dict[kSecCodeInfoIdentifier] as? String,
            signingValid: signingValid
        )
    }
}
