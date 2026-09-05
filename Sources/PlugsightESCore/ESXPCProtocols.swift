// ESXPCProtocols.swift
//
// The daemon<->extension XPC vocabulary (02), declared in the PURE layer so
// BOTH sides compile against one definition: the extension's listener
// (PlugsightESExtension) exports ESExtensionXPCProtocol, and the daemon's
// client (PlugsightDaemon) exports ESDaemonEventSinkProtocol on the same
// connection. Payloads are ESWire-encoded Data, never NSSecureCoding object
// graphs, so the wire shape stays frozen and debuggable.
//
// This file must stay free of EndpointSecurity (the ESCore purity guard greps
// for the import): NSXPCConnection vocabulary is Foundation, not ES.

import Foundation

/// Daemon -> extension: policy pushes. Payload is ESWire-encoded
/// ESPolicySnapshot. The acknowledgement reports whether the extension
/// decoded and cached the snapshot (false = dropped; the cache goes stale at
/// worst, and stale fails open). The daemon treats a recent acknowledgement
/// as THE live-handshake proof for status reporting: no ack, no "active".
@objc public protocol ESExtensionXPCProtocol {
    func pushPolicy(_ payload: Data, acknowledgement: @escaping (Bool) -> Void)
}

/// Extension -> daemon: compact observed events (ESWire-encoded
/// ESObservedEvent). Implemented by the daemon's exported object. Fire and
/// forget: a daemon that is gone simply misses events, which the monitoring
/// gap record already covers.
@objc public protocol ESDaemonEventSinkProtocol {
    func deliverEvent(_ payload: Data)
}
