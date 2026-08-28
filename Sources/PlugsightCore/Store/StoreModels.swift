// StoreModels.swift
//
// Plain, platform-neutral value types returned by EventStore reads. These are
// the shapes the API/MCP layers (N4+) render; they carry no GRDB or SQLite
// types across the boundary.

import Foundation

/// A stored history row (events table).
public struct StoredEvent: Equatable, Sendable {
    public let id: String
    public let at: String
    public let kind: String
    public let severity: String
    public let deviceID: String?
    public let actor: String
    public let summary: String
    public let detail: String
    public let alertID: String?
}

/// One interface row (device_interfaces table).
public struct StoredInterface: Equatable, Sendable {
    public let seq: Int
    public let usbClass: Int
    public let usbSubclass: Int
    public let usbProtocol: Int
    public let role: String
}

/// A full device record with its interfaces (devices + device_interfaces).
public struct StoredDevice: Equatable, Sendable {
    public let id: String
    public let identityKey: String
    public let identityBasis: String
    public let vid: Int
    public let pid: Int
    public let serial: String?
    public let vendorName: String?
    public let productName: String?
    public let displayName: String
    public let firstSeenAt: String
    public let lastSeenAt: String
    public let present: Bool
    public let trustTier: String
    public let trustNote: String?
    public let trustSetBy: String?
    public let trustSetAt: String?
    public let interfaces: [StoredInterface]
}

/// Result of an upsert: the device id and whether the row was newly created.
public struct UpsertResult: Equatable, Sendable {
    public let deviceID: String
    public let isNew: Bool
}

/// Filter for `listEvents`.
public struct EventFilter: Sendable {
    public var deviceID: String?
    public var kind: String?
    public init(deviceID: String? = nil, kind: String? = nil) {
        self.deviceID = deviceID
        self.kind = kind
    }
}

/// Filter for `listDevices`.
public struct DeviceFilter: Sendable {
    public var presentOnly: Bool
    public var trustTier: String?
    public init(presentOnly: Bool = false, trustTier: String? = nil) {
        self.presentOnly = presentOnly
        self.trustTier = trustTier
    }
}
