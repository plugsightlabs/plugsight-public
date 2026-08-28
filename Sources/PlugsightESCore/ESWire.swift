// ESWire.swift
//
// The daemon<->extension wire (02): events flow extension -> daemon as compact
// structs; cached policy (ESPolicySnapshot) flows daemon -> extension. JSON
// encoding with explicit ISO-less epoch dates — stable, debuggable, and free
// of NSSecureCoding class allow-list pitfalls (payloads cross XPC as Data).
// Receivers treat decode failure as drop-and-log: a bad policy payload just
// leaves the cache stale, and stale fails open.

import Foundation

/// One observed ES event, compact. Optionals stay nil for kinds where the
/// field does not apply (encoder omits them).
public struct ESObservedEvent: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable, CaseIterable {
        /// ES_EVENT_TYPE_NOTIFY_IOKIT_OPEN — which process opened which class.
        case iokitOpen
        /// ES_EVENT_TYPE_NOTIFY_MOUNT — volume appeared.
        case mount
        /// ES_EVENT_TYPE_NOTIFY_UNMOUNT — volume went away.
        case unmount
        /// The record of an AUTH_MOUNT answer (the decision itself is made
        /// locally; this event reports what was answered and why).
        case authMountDecision
    }

    public let kind: Kind
    public let timestamp: Date
    /// BSD name involved, e.g. "disk4s1" (mount/unmount/auth kinds).
    public let bsdName: String?
    /// Mount path when known, e.g. "/Volumes/UNTITLED".
    public let mountPath: String?
    /// Initiating process, when the event carries one.
    public let pid: Int32?
    public let processPath: String?
    /// For .authMountDecision: what was answered.
    public let decision: ESAuthDecision?

    public init(
        kind: Kind,
        timestamp: Date,
        bsdName: String? = nil,
        mountPath: String? = nil,
        pid: Int32? = nil,
        processPath: String? = nil,
        decision: ESAuthDecision? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.bsdName = bsdName
        self.mountPath = mountPath
        self.pid = pid
        self.processPath = processPath
        self.decision = decision
    }
}

// ESAuthDecision crosses the wire inside .authMountDecision events. Encoded
// as {"verdict":"allow"|"deny","reason":...} — explicit, not synthesized, so
// the wire shape is frozen independently of the enum's Swift layout.
extension ESAuthDecision: Codable {
    private enum CodingKeys: String, CodingKey { case verdict, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let verdict = try c.decode(String.self, forKey: .verdict)
        let reason = try c.decode(ESDecisionReason.self, forKey: .reason)
        switch verdict {
        case "allow": self = .allow(reason)
        case "deny": self = .deny(reason)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .verdict, in: c, debugDescription: "unknown verdict \(verdict)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isDeny ? "deny" : "allow", forKey: .verdict)
        try c.encode(reason, forKey: .reason)
    }
}

/// Encode/decode helpers both sides use, so the date strategy can never
/// drift between daemon and extension.
public enum ESWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}
