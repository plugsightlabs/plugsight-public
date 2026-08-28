// DeviceIdentity.swift
//
// Stable device identity (docs/spec/06 "Device identity, honestly"). USB gives
// no reliable identity, so we key devices in a defined order:
//
//  1. (vid, pid, serial) when the serial is present and NON-TRIVIAL
//     (length > 3 AND not all zeros). identity_basis = "serial".
//  2. Otherwise a SHAPE FINGERPRINT: SHA-256 over vid, pid, the ordered
//     interface triples (class, subclass, protocol), and the descriptor
//     strings (vendor_name, product_name). identity_basis = "shape".
//     => Two serialless identical sticks collapse to ONE row.
//
// CryptoKit's SHA256 is used here. It is not a platform-UI framework (not
// IOKit/CoreGraphics/EndpointSecurity), so the platform-neutrality seam holds;
// ops/check-seam.sh still passes.

import Foundation
import CryptoKit

/// The computed identity for a device: its stable key and the basis used.
public struct DeviceIdentity: Equatable {
    /// The UNIQUE key stored in devices.identity_key.
    public let key: String
    /// "serial" or "shape" — stored in devices.identity_basis.
    public let basis: String
}

public enum DeviceIdentifier {
    /// True when a serial string is present and non-trivial: longer than 3
    /// characters AND not composed entirely of '0'.
    static func isNonTrivialSerial(_ serial: String?) -> Bool {
        guard let serial else { return false }
        guard serial.count > 3 else { return false }
        if serial.allSatisfy({ $0 == "0" }) { return false }
        return true
    }

    /// Compute the identity key + basis for a device.
    public static func compute(
        vid: Int,
        pid: Int,
        serial: String?,
        vendorName: String?,
        productName: String?,
        interfaces: [InterfaceDescriptor]
    ) -> DeviceIdentity {
        if isNonTrivialSerial(serial), let serial {
            return DeviceIdentity(key: "serial:\(vid):\(pid):\(serial)", basis: "serial")
        }
        return DeviceIdentity(key: "shape:\(shapeFingerprint(vid: vid, pid: pid, vendorName: vendorName, productName: productName, interfaces: interfaces))", basis: "shape")
    }

    /// SHA-256 hex over a canonical, deterministic serialization of the device
    /// shape. Interfaces are taken in configuration (seq) order.
    static func shapeFingerprint(
        vid: Int,
        pid: Int,
        vendorName: String?,
        productName: String?,
        interfaces: [InterfaceDescriptor]
    ) -> String {
        let ordered = interfaces.sorted { $0.seq < $1.seq }
        let triples = ordered
            .map { "\($0.usbClass):\($0.usbSubclass):\($0.usbProtocol)" }
            .joined(separator: ",")
        // Field separators are characters that cannot appear inside the numeric
        // fields, keeping the serialization unambiguous.
        let canonical = "\(vid)|\(pid)|\(triples)|\(vendorName ?? "")|\(productName ?? "")"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
