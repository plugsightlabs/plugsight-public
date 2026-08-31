// CollectorMappingTests.swift
//
// N5 CI-runnable gate: pure mapping from captured IORegistry property
// dictionaries (JSON fixtures in Tests/Fixtures/iokit/) to the frozen N1
// contract types. The live IOKit/IOHIDManager/DiskArbitration plumbing is NOT
// tested here — it needs real hardware and is exercised by the manual probe
// (ops/dev-attach-probe.swift).

import XCTest
import Foundation
@testable import PlugsightDaemon
import PlugsightCore

final class CollectorMappingTests: XCTestCase {

    // MARK: - Volume scope (only user-plugged drives, never internal/system media)

    func testInternalAndNetworkVolumesAreNotTracked() {
        // Internal system media (boot volume, Preboot, VM, xarts…) reports
        // DeviceInternal == true → skipped, so scan-on-mount never runs clamscan
        // on unreadable system volumes ("Scan of “xarts” failed (engine error)").
        XCTAssertFalse(DiskArbitrationSource.isTrackableVolume(isInternal: true, isNetwork: false))
        XCTAssertFalse(DiskArbitrationSource.isTrackableVolume(isInternal: true, isNetwork: nil))
        // Network mounts are out of scope too.
        XCTAssertFalse(DiskArbitrationSource.isTrackableVolume(isInternal: false, isNetwork: true))
    }

    func testExternalVolumesAreTracked() {
        // A plugged-in drive: external, not network → tracked and scanned.
        XCTAssertTrue(DiskArbitrationSource.isTrackableVolume(isInternal: false, isNetwork: false))
        // Absent flags must NOT drop a real external drive (fail open to tracking).
        XCTAssertTrue(DiskArbitrationSource.isTrackableVolume(isInternal: nil, isNetwork: nil))
    }

    // MARK: - Fixture loading

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PlugsightDaemonTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures/iokit/\(name)")
    }

    private func loadDevice(_ name: String) throws -> IORegistryUSBDevice {
        let data = try Data(contentsOf: fixtureURL(name))
        return try JSONDecoder().decode(IORegistryUSBDevice.self, from: data)
    }

    // MARK: - keyboard.json

    func testKeyboardFixtureMapsToDescriptor() throws {
        let device = try loadDevice("keyboard.json")
        let descriptor = CollectorMapping.deviceDescriptor(from: device)

        XCTAssertEqual(descriptor.vid, 0x046D) // 1133, Logitech
        XCTAssertEqual(descriptor.pid, 0xC31C) // 49948
        XCTAssertEqual(descriptor.serial, "057B12345678")
        XCTAssertEqual(descriptor.vendorName, "Logitech")
        XCTAssertEqual(descriptor.productName, "USB Keyboard")
        XCTAssertEqual(descriptor.portPath, "20-2")
        XCTAssertEqual(descriptor.interfaces, [
            InterfaceDescriptor(seq: 0, usbClass: 3, usbSubclass: 1, usbProtocol: 1)
        ])
        XCTAssertFalse(descriptor.deviceKey.isEmpty)
    }

    // MARK: - serialless-stick.json

    func testSeriallessStickYieldsNilSerial() throws {
        let device = try loadDevice("serialless-stick.json")
        let descriptor = CollectorMapping.deviceDescriptor(from: device)

        XCTAssertNil(descriptor.serial, "no serial: downstream identity must fall to shape fingerprint (N2)")
        XCTAssertEqual(descriptor.vid, 0x090C)
        XCTAssertEqual(descriptor.pid, 0x1000)
        XCTAssertEqual(descriptor.vendorName, "USB")
        XCTAssertEqual(descriptor.productName, "DISK 2.0")
        XCTAssertEqual(descriptor.portPath, "1-1")
        XCTAssertEqual(descriptor.interfaces, [
            InterfaceDescriptor(seq: 0, usbClass: 8, usbSubclass: 6, usbProtocol: 80)
        ])
        XCTAssertFalse(descriptor.deviceKey.isEmpty)
    }

    // MARK: - hub-composite.json

    func testHubCompositeInterfacesMappedTripleForTripleInOrder() throws {
        let device = try loadDevice("hub-composite.json")
        let descriptor = CollectorMapping.deviceDescriptor(from: device)

        XCTAssertEqual(descriptor.vid, 0x05E3)
        XCTAssertEqual(descriptor.pid, 0x0610)
        XCTAssertEqual(descriptor.serial, "GL352000")
        XCTAssertEqual(descriptor.interfaces, [
            InterfaceDescriptor(seq: 0, usbClass: 9, usbSubclass: 0, usbProtocol: 1),
            InterfaceDescriptor(seq: 1, usbClass: 3, usbSubclass: 0, usbProtocol: 0),
        ], "interface triples must be preserved in configuration order")
        XCTAssertEqual(descriptor.portPath, "20-3")
    }

    // MARK: - junk-strings.json

    func testJunkStringsPreservedByteForByteWithoutCrash() throws {
        let device = try loadDevice("junk-strings.json")
        let descriptor = CollectorMapping.deviceDescriptor(from: device)

        // The collector reports facts; it never sanitizes. Byte-for-byte pass-through.
        let expectedVendor = "\u{07}V\u{1B}endor\u{FF}\u{C3}\u{BC}\u{FFFD}"
        let expectedProduct = "PR\u{00}ODUCT\u{9F}"

        XCTAssertEqual(Array(descriptor.vendorName!.utf8), Array(expectedVendor.utf8))
        XCTAssertEqual(Array(descriptor.productName!.utf8), Array(expectedProduct.utf8))
        // And byte-for-byte identical to what the fixture carried in.
        XCTAssertEqual(Array(descriptor.vendorName!.utf8), Array(device.usbVendorName!.utf8))
        XCTAssertEqual(Array(descriptor.productName!.utf8), Array(device.usbProductName!.utf8))
        XCTAssertNil(descriptor.serial)
        XCTAssertFalse(descriptor.deviceKey.isEmpty)
    }

    // MARK: - deviceKey stability

    func testDeviceKeyIsStableForTheSamePhysicalPortAndDistinctAcrossPorts() throws {
        let a1 = CollectorMapping.deviceDescriptor(from: try loadDevice("keyboard.json"))
        let a2 = CollectorMapping.deviceDescriptor(from: try loadDevice("keyboard.json"))
        XCTAssertEqual(a1.deviceKey, a2.deviceKey, "same registry facts must derive the same key within a session")
        XCTAssertFalse(a1.deviceKey.isEmpty)

        let others = try ["serialless-stick.json", "hub-composite.json", "junk-strings.json"]
            .map { CollectorMapping.deviceDescriptor(from: try loadDevice($0)) }
        for other in others {
            XCTAssertNotEqual(a1.deviceKey, other.deviceKey, "different ports must derive different keys")
        }
    }

    func testDeviceKeyFallsBackWhenLocationIDMissing() {
        let noLocation = IORegistryUSBDevice(
            idVendor: 1, idProduct: 2,
            usbSerialNumber: nil, usbVendorName: nil, usbProductName: nil,
            locationID: nil, portPath: "3-1.2",
            interfaces: []
        )
        let byPath = CollectorMapping.deviceDescriptor(from: noLocation)
        XCTAssertFalse(byPath.deviceKey.isEmpty)

        let bare = IORegistryUSBDevice(
            idVendor: 1, idProduct: 2,
            usbSerialNumber: nil, usbVendorName: nil, usbProductName: nil,
            locationID: nil, portPath: nil,
            interfaces: []
        )
        XCTAssertFalse(CollectorMapping.deviceDescriptor(from: bare).deviceKey.isEmpty)
        XCTAssertNotEqual(byPath.deviceKey, CollectorMapping.deviceDescriptor(from: bare).deviceKey)
    }

    // MARK: - portPath derivation from locationID (used by the live source)

    func testPortPathDerivationFromLocationID() {
        XCTAssertEqual(CollectorMapping.portPath(fromLocationID: 0x14200000), "20-2")
        XCTAssertEqual(CollectorMapping.portPath(fromLocationID: 0x14240000), "20-2.4")
        XCTAssertEqual(CollectorMapping.portPath(fromLocationID: 0x01100000), "1-1")
        XCTAssertEqual(CollectorMapping.portPath(fromLocationID: 0x14000000), "20", "root (no port nibbles) is just the bus")
    }

    // MARK: - DiskArbitration volume mapping

    func testVolumeMountedMapsToVolumeMountedEvent() {
        let description = DiskArbitrationVolume(
            deviceKey: "usb-loc-0x01100000",
            volumePath: "/Volumes/STICK",
            volumeName: "STICK",
            totalBytes: 15_500_000_000
        )
        let event = CollectorMapping.volumeEvent(mounted: description)
        XCTAssertEqual(event, .volumeMounted(VolumeDescriptor(
            deviceKey: "usb-loc-0x01100000",
            volumePath: "/Volumes/STICK",
            volumeName: "STICK",
            totalBytes: 15_500_000_000
        )))
    }

    func testVolumeUnmountMapsToVolumeUnmountedEvent() {
        let at = Date(timeIntervalSince1970: 1_724_500_000)
        let event = CollectorMapping.volumeEvent(
            unmountedDeviceKey: "usb-loc-0x01100000",
            volumePath: "/Volumes/STICK",
            at: at
        )
        XCTAssertEqual(event, .volumeUnmounted(
            deviceKey: "usb-loc-0x01100000",
            volumePath: "/Volumes/STICK",
            at: at
        ))
    }
}
