import XCTest
@testable import PlugsightCore
import PlugsightTestKit

final class CollectorEventTests: XCTestCase {

    /// A trivial array-backed source satisfies the DeviceEventSource protocol and
    /// replays its events in order, then finishes. This fake is the backbone of
    /// all later detection tests.
    func testFakeDeviceEventSourceSatisfiesProtocolAndReplaysInOrder() async throws {
        let attached = CollectorEvent.attached(
            DeviceDescriptor(
                deviceKey: "dev-1",
                vid: 0x05ac,
                pid: 0x024f,
                serial: "SER123",
                vendorName: "Acme",
                productName: "Widget Keyboard",
                interfaces: [
                    InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0x01, usbProtocol: 0x01)
                ],
                portPath: "0-1.2"
            )
        )
        let interfaces = CollectorEvent.interfacesRead(
            deviceKey: "dev-1",
            interfaces: [
                InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0x01, usbProtocol: 0x01)
            ]
        )
        let input = CollectorEvent.inputActivity(
            InputTiming(at: Date(timeIntervalSince1970: 1000), interKeyIntervalMs: nil)
        )
        let detached = CollectorEvent.detached(
            deviceKey: "dev-1",
            at: Date(timeIntervalSince1970: 2000)
        )
        let expected: [CollectorEvent] = [attached, interfaces, input, detached]

        // Compile-level: the fake must be usable through the protocol existential.
        let source: any DeviceEventSource = FakeDeviceEventSource(events: expected)
        try source.start()

        var received: [CollectorEvent] = []
        for await event in source.events {
            received.append(event)
        }
        source.stop()

        XCTAssertEqual(received, expected, "fake must replay events in order then finish")
    }
}
