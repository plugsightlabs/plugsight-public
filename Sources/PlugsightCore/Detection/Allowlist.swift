// Allowlist.swift
//
// The legit-composite allowlist (05): checked BEFORE R1-R4, shipped as DATA
// (allowlist.json, a PlugsightCore bundle resource) so updates need no
// release. It matches interface SHAPES, never VID/PID — a forged vendor id
// buys the attacker nothing here. A hit downgrades the enumeration to an
// info event naming the pattern ("composite device matching the
// security-key shape").
//
// Shape matching is strict both ways: every role in the pattern must be
// present among the interfaces, AND every interface must be covered by some
// role of the pattern. A "webcam" that also enumerates a keyboard is not the
// webcam shape.

import Foundation

/// The interface-role vocabulary shapes are written in. Data (the JSON) uses
/// these raw values; the predicates live here in code.
public enum AllowlistRole: String, Codable, Sendable, CaseIterable {
    /// Any HID interface (class 0x03), keyboard or not.
    case hid
    /// HID boot keyboard (0x03, protocol 0x01).
    case keyboard
    /// HID boot mouse (0x03, protocol 0x02).
    case mouse
    /// Smartcard CCID (0x0B).
    case ccid
    /// Vendor-specific (0xFF).
    case vendor
    /// Hub (0x09).
    case hub
    /// Audio (0x01).
    case audio
    /// Video (0x0E).
    case video
    /// Billboard (0x11).
    case billboard
    /// CDC ECM/NCM, RNDIS, or CDC-data.
    case network

    func matches(_ i: InterfaceDescriptor) -> Bool {
        switch self {
        case .hid: return InterfaceClassifier.isHID(i)
        case .keyboard: return InterfaceClassifier.isKeyboard(i)
        case .mouse: return InterfaceClassifier.isMouse(i)
        case .ccid: return i.usbClass == USBInterfaceClass.ccid
        case .vendor: return i.usbClass == USBInterfaceClass.vendorSpecific
        case .hub: return i.usbClass == USBInterfaceClass.hub
        case .audio: return i.usbClass == USBInterfaceClass.audio
        case .video: return i.usbClass == USBInterfaceClass.video
        case .billboard: return i.usbClass == USBInterfaceClass.billboard
        case .network: return InterfaceClassifier.isNetwork(i)
        }
    }
}

/// One legit-composite shape from the data file.
public struct AllowlistPattern: Equatable, Sendable, Decodable {
    /// Stable identifier, quoted in the downgraded event ("security-key").
    public let id: String
    /// Human-readable description of the shape.
    public let description: String
    /// Roles that must all be present, and that must cover every interface.
    public let roles: [AllowlistRole]

    public init(id: String, description: String, roles: [AllowlistRole]) {
        self.id = id
        self.description = description
        self.roles = roles
    }

    /// Strict two-way shape match (see file header).
    public func matches(_ interfaces: [InterfaceDescriptor]) -> Bool {
        guard !interfaces.isEmpty else { return false }
        let everyRolePresent = roles.allSatisfy { role in
            interfaces.contains(where: role.matches)
        }
        let everyInterfaceCovered = interfaces.allSatisfy { i in
            roles.contains { $0.matches(i) }
        }
        return everyRolePresent && everyInterfaceCovered
    }
}

public enum AllowlistError: Error, Equatable {
    /// allowlist.json is missing from the PlugsightCore resource bundle.
    case shippedResourceMissing
}

/// The loaded allowlist. Matching consumes interface descriptors only —
/// VID/PID never participate.
public struct Allowlist: Equatable, Sendable {
    public let patterns: [AllowlistPattern]

    /// No shapes; every enumeration goes to the rules at full severity.
    public static let empty = Allowlist(patterns: [])

    public init(patterns: [AllowlistPattern]) {
        self.patterns = patterns
    }

    /// Decode from the shipped JSON format. Unknown roles fail decoding
    /// loudly rather than silently matching nothing.
    public init(jsonData: Data) throws {
        struct File: Decodable {
            let version: Int
            let patterns: [AllowlistPattern]
        }
        self.patterns = try JSONDecoder().decode(File.self, from: jsonData).patterns
    }

    /// Load the allowlist shipped as a PlugsightCore bundle resource.
    public static func loadShipped() throws -> Allowlist {
        guard let url = Bundle.module.url(forResource: "allowlist", withExtension: "json") else {
            throw AllowlistError.shippedResourceMissing
        }
        return try Allowlist(jsonData: Data(contentsOf: url))
    }

    /// First pattern whose shape matches, or nil. Shape-only: no VID/PID.
    public func match(_ interfaces: [InterfaceDescriptor]) -> AllowlistPattern? {
        patterns.first { $0.matches(interfaces) }
    }
}
