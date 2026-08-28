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

/// Daemon -> extension: policy pushes. Payload is ESWire-encoded
/// ESPolicySnapshot; a payload that fails to decode is dropped and logged
/// (the cache goes stale at worst, and stale fails open).
@objc public protocol ESExtensionXPCProtocol {
    func pushPolicy(_ payload: Data)
}

/// Extension -> daemon: compact observed events (ESWire-encoded
/// ESObservedEvent). Implemented by the daemon's exported object.
@objc public protocol ESDaemonEventSinkProtocol {
    func deliverEvent(_ payload: Data)
}

public final class ESXPCListener: NSObject, NSXPCListenerDelegate, ESExtensionXPCProtocol {
    private let log = Logger(subsystem: "com.plugsight.esext", category: "xpc")
    private let listener: NSXPCListener
    private let requirement: ESPeerRequirement
    /// Exact bundle id the connecting daemon must present (02's table).
    private let daemonBundleID: String
    private let cacheBox: ESPolicyCacheBox

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
        connection.resume()
        log.log("accepted daemon connection pid \(connection.processIdentifier)")
        return true
    }

    // MARK: - ESExtensionXPCProtocol

    public func pushPolicy(_ payload: Data) {
        do {
            let snapshot = try ESWire.decode(ESPolicySnapshot.self, from: payload)
            cacheBox.update(snapshot)
            log.log("policy snapshot updated (hold=\(snapshot.holdUntilScanned), \(snapshot.trustByDeviceKey.count) devices)")
        } catch {
            // Drop-and-log: a bad payload leaves the cache stale, and stale
            // fails open. Never crash the extension over daemon input.
            log.error("dropping undecodable policy payload: \(error)")
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
