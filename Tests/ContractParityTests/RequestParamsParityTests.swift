// RequestParamsParityTests.swift
//
// Request-side parity: the app client's PARAMS must decode into the daemon's
// typed params the way the daemon actually reads them. The response-side gate
// (CrossDecodeParityTests) never covered request shapes, so the app once sent
// `{"deviceId": id}` to scans.list while the daemon read `p.filter?.deviceId` —
// the filter silently decoded as nil and every device's scans came back. These
// tests feed the client's real param dictionaries through the daemon's real
// decode path so that class of drift fails loudly.

import Foundation
import XCTest
@testable import PlugsightDaemon
@testable import PlugsightAppCore
import PlugsightCore

final class RequestParamsParityTests: XCTestCase {

    /// Serialize a client param dictionary exactly as LiveAPIClient does
    /// (JSONSerialization), then decode it through the daemon's typed path.
    private func daemonDecode<T: Decodable>(_ params: [String: Any], as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: params)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // The bug this file exists for: scans.list params must nest deviceId under
    // `filter` (the daemon reads p.filter?.deviceId; a top-level deviceId is
    // silently ignored and the list comes back unfiltered).
    func testScansListParamsNestDeviceIdUnderFilter() throws {
        let params = LiveAPIClient.scansListParams(deviceId: "dev_abc")
        let decoded = try daemonDecode(params, as: ScansListParams.self)
        XCTAssertEqual(decoded.filter?.deviceId, "dev_abc",
                       "scans.list must send {filter:{deviceId}}; a top-level deviceId decodes as filter=nil and returns every device's scans")
    }

    // Full round trip: the client's params, decoded by the daemon, actually
    // FILTER a seeded store with scans on two devices.
    func testScansListParamsFilterTheRouterResult() throws {
        let dir = "/tmp/ps-reqparity-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let event = try EventStore(path: (dir as NSString).appendingPathComponent("plugsight.db"))
        let store = try APIStore(store: event)

        let devA = try event.upsertDevice(from: DeviceDescriptor(
            deviceKey: "a", vid: 0x0781, pid: 0x5581, serial: "A1",
            vendorName: "SanDisk", productName: "Ultra",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 6, usbProtocol: 80)],
            portPath: "20-1")).deviceID
        let devB = try event.upsertDevice(from: DeviceDescriptor(
            deviceKey: "b", vid: 0x0781, pid: 0x5583, serial: "B1",
            vendorName: "SanDisk", productName: "Extreme",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x08, usbSubclass: 6, usbProtocol: 80)],
            portPath: "20-2")).deviceID
        _ = try store.insertScan(deviceID: devA, volumePath: "/Volumes/A", engine: "clamdscan", startedBy: "ui")
        _ = try store.insertScan(deviceID: devB, volumePath: "/Volumes/B", engine: "clamdscan", startedBy: "ui")

        let router = Router(
            store: store, broadcaster: EventBroadcaster(), daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
            startedAt: Date(), quarantineDirectory: (dir as NSString).appendingPathComponent("quarantine"))

        let decoded = try daemonDecode(LiveAPIClient.scansListParams(deviceId: devA), as: ScansListParams.self)
        let result = try router.scansList(decoded)
        XCTAssertEqual(result.scans.count, 1, "the filter must exclude the other device's scan")
        XCTAssertEqual(result.scans.first?.deviceId, devA)
    }
}
