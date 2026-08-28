// CollectorEvent.swift
//
// The cross-platform seam (docs/spec/02). This file defines the FROZEN contract
// between platform-specific device event sources (which will live in
// PlugsightDaemon: IOKitDeviceSource, HIDTimingSource, ESEventSource) and the
// platform-neutral core.
//
// PlugsightCore MUST NOT import IOKit, CoreGraphics, or EndpointSecurity. Every
// fact carried across this seam is expressed in 06's platform-neutral vocabulary:
// integers (USB class codes, ids, byte counts), strings (names, paths), and
// `Date` timestamps. Identity keying, role mapping, and display-name computation
// are LATER nodes' jobs (N2) — the descriptors here carry raw facts only.
//
// Consumed unchanged by N2, N3, N5, N6, N12.

import Foundation

/// Facts about a single USB interface, in configuration order.
///
/// Carries the raw class triple plus its sequence index. Role mapping to
/// plain-language words (keyboard, mass storage, ...) is a later node's job and
/// is deliberately NOT baked into this contract.
public struct InterfaceDescriptor: Equatable, Codable, Sendable {
    /// Position of this interface in the device's configuration (0-based, in config order).
    public let seq: Int
    /// USB interface class code (standard integer code, e.g. 0x03 for HID).
    public let usbClass: Int
    /// USB interface subclass code.
    public let usbSubclass: Int
    /// USB interface protocol code.
    public let usbProtocol: Int

    public init(seq: Int, usbClass: Int, usbSubclass: Int, usbProtocol: Int) {
        self.seq = seq
        self.usbClass = usbClass
        self.usbSubclass = usbSubclass
        self.usbProtocol = usbProtocol
    }
}

/// Facts about a single physical device as seen at attach time.
///
/// Carries only raw descriptor facts. The `deviceKey` is an opaque transient
/// key the source assigns to correlate attach/detach/interfaces/input/volume
/// events for one physical device within a single source session; it is NOT a
/// stable identity (that is N2's job).
public struct DeviceDescriptor: Equatable, Codable, Sendable {
    /// Opaque transient key the source assigns to correlate events for one
    /// physical device. Not a stable identity across sessions.
    public let deviceKey: String
    /// USB vendor id.
    public let vid: Int
    /// USB product id.
    public let pid: Int
    /// Serial number descriptor string, if the device reports one.
    public let serial: String?
    /// Vendor name descriptor string. May be junk or empty; carried raw.
    public let vendorName: String?
    /// Product name descriptor string. May be junk or empty; carried raw.
    public let productName: String?
    /// Interfaces in configuration order.
    public let interfaces: [InterfaceDescriptor]
    /// Topology hint: a port path string (which port / behind which hub), if known.
    public let portPath: String?

    public init(
        deviceKey: String,
        vid: Int,
        pid: Int,
        serial: String?,
        vendorName: String?,
        productName: String?,
        interfaces: [InterfaceDescriptor],
        portPath: String?
    ) {
        self.deviceKey = deviceKey
        self.vid = vid
        self.pid = pid
        self.serial = serial
        self.vendorName = vendorName
        self.productName = productName
        self.interfaces = interfaces
        self.portPath = portPath
    }
}

/// Facts about a mounted volume, tied to its owning device by `deviceKey`.
public struct VolumeDescriptor: Equatable, Codable, Sendable {
    /// Owning device key, so a mount can be tied back to a device.
    public let deviceKey: String
    /// Mounted volume path (String).
    public let volumePath: String
    /// Volume name, if known.
    public let volumeName: String?
    /// Total size in bytes, if known.
    public let totalBytes: Int?

    public init(deviceKey: String, volumePath: String, volumeName: String?, totalBytes: Int?) {
        self.deviceKey = deviceKey
        self.volumePath = volumePath
        self.volumeName = volumeName
        self.totalBytes = totalBytes
    }
}

/// PRIVACY WALL (load-bearing).
///
/// Timing metadata ONLY: an event timestamp and an inter-keystroke interval in
/// milliseconds. This struct MUST NOT ever carry a key code, character, or any
/// typed content. N6 asserts by reflection that no content field exists — keep
/// it that way.
public struct InputTiming: Equatable, Codable, Sendable {
    /// When the input event occurred.
    public let at: Date
    /// Milliseconds since the previous key in the burst; nil for the first key.
    public let interKeyIntervalMs: Int?

    public init(at: Date, interKeyIntervalMs: Int?) {
        self.at = at
        self.interKeyIntervalMs = interKeyIntervalMs
    }
}

/// A single event emitted across the collector seam.
public enum CollectorEvent: Equatable, Sendable {
    /// A device was attached; carries its descriptor.
    case attached(DeviceDescriptor)
    /// A device was detached, identified by its transient key.
    case detached(deviceKey: String, at: Date)
    /// A device's interfaces were read (may arrive after `attached`).
    case interfacesRead(deviceKey: String, interfaces: [InterfaceDescriptor])
    /// A volume belonging to a device was mounted.
    case volumeMounted(VolumeDescriptor)
    /// A volume belonging to a device was unmounted.
    case volumeUnmounted(deviceKey: String, volumePath: String, at: Date)
    /// Input timing metadata (privacy wall: timing only, never content).
    case inputActivity(InputTiming)
}

/// The cross-platform seam.
///
/// Platform-specific implementations (IOKitDeviceSource, HIDTimingSource,
/// ESEventSource) will live in PlugsightDaemon and conform to this protocol.
/// Core code consumes `events` without importing any platform framework.
public protocol DeviceEventSource: AnyObject, Sendable {
    /// The stream of collector events. Finishes when the source stops.
    var events: AsyncStream<CollectorEvent> { get }
    /// Begin producing events. May throw if the underlying platform source fails to start.
    func start() throws
    /// Stop producing events and finish the stream.
    func stop()
}
