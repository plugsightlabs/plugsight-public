// CollectorMapping.swift
//
// The PURE half of the N5 collector (docs/spec/02, docs/spec/07): mapping from
// IORegistry property dictionaries — captured as Codable values, decoupled from
// live IOKit — into the frozen N1 contract types (PlugsightCore).
//
// Everything in this file is deterministic, platform-neutral Swift and is
// unit-tested against JSON fixtures in Tests/Fixtures/iokit/. The live
// IOKit/IOHIDManager/DiskArbitration plumbing (IOKitDeviceSource,
// HIDTimingSource, DiskArbitrationSource) is deliberately THIN: it reads the
// registry into these structs, calls these functions, and yields the result.
//
// The collector reports FACTS. Strings (vendor/product/serial) are passed
// through raw — junk bytes, control characters, mojibake and all. Sanitizing
// or prettifying is the store/UI's decision, never the collector's.

import Foundation
import PlugsightCore

/// What we read out of the IORegistry for one USB device.
///
/// Coding keys are the documented IORegistry property names for a USB device
/// (`idVendor`, `idProduct`, `USB Serial Number`, `USB Vendor Name`,
/// `USB Product Name`, `locationID`), so a fixture is a faithful capture of the
/// registry dictionary. `portPath` and `interfaces` are derived during the
/// registry walk, not raw device properties.
struct IORegistryUSBDevice: Codable, Equatable, Sendable {
    var idVendor: Int
    var idProduct: Int
    var usbSerialNumber: String?
    var usbVendorName: String?
    var usbProductName: String?
    var locationID: Int?
    var portPath: String?
    var interfaces: [IORegistryUSBInterface]

    enum CodingKeys: String, CodingKey {
        case idVendor
        case idProduct
        case usbSerialNumber = "USB Serial Number"
        case usbVendorName = "USB Vendor Name"
        case usbProductName = "USB Product Name"
        case locationID
        case portPath
        case interfaces
    }
}

/// One interface as read from an `IOUSBHostInterface` registry entry.
/// `bInterfaceClass`/`bInterfaceSubClass`/`bInterfaceProtocol` are the
/// documented registry property names; `seq` is the 0-based position in
/// configuration order, assigned during the walk.
struct IORegistryUSBInterface: Codable, Equatable, Sendable {
    var seq: Int
    var bInterfaceClass: Int
    var bInterfaceSubClass: Int
    var bInterfaceProtocol: Int
}

/// A DiskArbitration disk description reduced to the facts the seam carries,
/// with the owning device already resolved to its collector `deviceKey`.
struct DiskArbitrationVolume: Codable, Equatable, Sendable {
    var deviceKey: String
    var volumePath: String
    var volumeName: String?
    var totalBytes: Int?
}

/// Pure mapping functions: registry facts in, frozen N1 contract values out.
enum CollectorMapping {

    /// Maps one captured USB device registry dictionary to the N1 descriptor.
    ///
    /// - vid/pid/serial/vendorName/productName pass through raw (no sanitizing).
    /// - Interfaces map triple-for-triple, preserving configuration order.
    /// - `deviceKey` derives from locationID (preferred) or portPath, so it is
    ///   stable per physical port for the session. It is NOT a cross-session
    ///   identity — that is N2's job.
    static func deviceDescriptor(from device: IORegistryUSBDevice) -> DeviceDescriptor {
        DeviceDescriptor(
            deviceKey: deviceKey(for: device),
            vid: device.idVendor,
            pid: device.idProduct,
            serial: device.usbSerialNumber,
            vendorName: device.usbVendorName,
            productName: device.usbProductName,
            interfaces: device.interfaces.map {
                InterfaceDescriptor(
                    seq: $0.seq,
                    usbClass: $0.bInterfaceClass,
                    usbSubclass: $0.bInterfaceSubClass,
                    usbProtocol: $0.bInterfaceProtocol
                )
            },
            portPath: device.portPath
        )
    }

    /// Transient per-session device key, stable for one physical port.
    /// Preference order: locationID (uniquely identifies bus+port chain on this
    /// boot), then portPath, then vid/pid as a last resort.
    static func deviceKey(for device: IORegistryUSBDevice) -> String {
        if let locationID = device.locationID {
            return String(format: "usb-loc-0x%08x", UInt32(truncatingIfNeeded: locationID))
        }
        if let portPath = device.portPath, !portPath.isEmpty {
            return "usb-port-\(portPath)"
        }
        return "usb-vidpid-\(device.idVendor)-\(device.idProduct)"
    }

    /// Derives a human-readable hub/port path from a USB locationID.
    ///
    /// The high byte is the bus; the remaining nibbles, read high-to-low until
    /// the first zero, are the port chain (each hop through a hub adds one).
    /// Example: 0x14240000 -> bus 0x14, ports 2 then 4 -> "20-2.4".
    static func portPath(fromLocationID locationID: Int) -> String {
        let location = UInt32(truncatingIfNeeded: locationID)
        let bus = location >> 24
        var ports: [String] = []
        var shift = 20
        while shift >= 0 {
            let nibble = (location >> UInt32(shift)) & 0xF
            if nibble == 0 { break }
            ports.append(String(nibble))
            shift -= 4
        }
        return ports.isEmpty ? String(bus) : "\(bus)-\(ports.joined(separator: "."))"
    }

    /// Maps a mounted-volume DiskArbitration description to the seam event.
    static func volumeEvent(mounted volume: DiskArbitrationVolume) -> CollectorEvent {
        .volumeMounted(VolumeDescriptor(
            deviceKey: volume.deviceKey,
            volumePath: volume.volumePath,
            volumeName: volume.volumeName,
            totalBytes: volume.totalBytes
        ))
    }

    /// Maps an unmount to the seam event.
    static func volumeEvent(unmountedDeviceKey deviceKey: String, volumePath: String, at: Date) -> CollectorEvent {
        .volumeUnmounted(deviceKey: deviceKey, volumePath: volumePath, at: at)
    }
}
