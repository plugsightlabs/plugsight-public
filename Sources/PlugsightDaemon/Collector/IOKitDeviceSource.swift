// IOKitDeviceSource.swift
//
// THIN live plumbing (docs/spec/02): IOServiceAddMatchingNotification for
// first-match and terminated on USB devices. On attach it reads the device's
// IORegistry properties into the pure `IORegistryUSBDevice` intermediate
// (walking IOUSBHostInterface children for the class triples, deriving the
// hub/port path from locationID) and hands it to `CollectorMapping` — ALL
// decisions live in the pure, unit-tested mapper. Notify-only: this source
// never opens, claims, or configures a device.
//
// This file cannot run in CI (it needs real IOKit hardware events); it is
// exercised by the manual probe `ops/dev-attach-probe.swift` (the named N5
// hardware gate). Keep it as thin as possible so the untested surface stays
// minimal.

import Foundation
import IOKit
import IOKit.usb
import PlugsightCore

public final class IOKitDeviceSource: DeviceEventSource, @unchecked Sendable {

    public var events: AsyncStream<CollectorEvent> { stream }

    private let stream: AsyncStream<CollectorEvent>
    private let continuation: AsyncStream<CollectorEvent>.Continuation

    private let lock = NSLock()
    private var notifyPort: IONotificationPortRef?
    private var firstMatchIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    /// registry entry id -> deviceKey, so `terminated` can name the device.
    private var deviceKeysByEntryID: [UInt64: String] = [:]

    public init() {
        var continuation: AsyncStream<CollectorEvent>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    deinit { stop() }

    // MARK: - DeviceEventSource

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard notifyPort == nil else { return }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw CollectorSourceError.notificationPortUnavailable
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue(label: "plugsight.iokit-device-source"))
        notifyPort = port

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // First match: existing devices are delivered through the initial
        // iterator drain, future attaches through the callback.
        var matched: io_iterator_t = 0
        let matchResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"),
            { refcon, iterator in
                guard let refcon else { return }
                Unmanaged<IOKitDeviceSource>.fromOpaque(refcon).takeUnretainedValue().handleFirstMatch(iterator)
            },
            refcon,
            &matched
        )
        guard matchResult == KERN_SUCCESS else {
            throw CollectorSourceError.matchingRegistrationFailed(matchResult)
        }
        firstMatchIterator = matched
        handleFirstMatch(matched) // drain: arms the notification, reports devices already present

        var terminated: io_iterator_t = 0
        let termResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            { refcon, iterator in
                guard let refcon else { return }
                Unmanaged<IOKitDeviceSource>.fromOpaque(refcon).takeUnretainedValue().handleTerminated(iterator)
            },
            refcon,
            &terminated
        )
        guard termResult == KERN_SUCCESS else {
            throw CollectorSourceError.matchingRegistrationFailed(termResult)
        }
        terminatedIterator = terminated
        handleTerminated(terminated) // drain to arm; usually empty at start
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if firstMatchIterator != 0 { IOObjectRelease(firstMatchIterator); firstMatchIterator = 0 }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator); terminatedIterator = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
            continuation.finish()
        }
    }

    // MARK: - Notification handling (thin: read registry, call pure mapper, yield)

    private func handleFirstMatch(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let registryDevice = IOKitRegistryReader.readUSBDevice(service)
            let descriptor = CollectorMapping.deviceDescriptor(from: registryDevice)
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            lock.lock()
            deviceKeysByEntryID[entryID] = descriptor.deviceKey
            lock.unlock()
            continuation.yield(.attached(descriptor))
        }
    }

    private func handleTerminated(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            lock.lock()
            let known = deviceKeysByEntryID.removeValue(forKey: entryID)
            lock.unlock()
            // Fall back to re-reading the (dying) registry entry if we never
            // saw the attach — still notify-only, still via the pure mapper.
            let deviceKey = known
                ?? CollectorMapping.deviceKey(for: IOKitRegistryReader.readUSBDevice(service))
            continuation.yield(.detached(deviceKey: deviceKey, at: Date()))
        }
    }
}

public enum CollectorSourceError: Error, Equatable {
    case notificationPortUnavailable
    case matchingRegistrationFailed(kern_return_t)
    case hidManagerOpenFailed(IOReturn)
    case diskArbitrationSessionUnavailable
}

/// Reads one live `io_service_t` USB device into the pure Codable intermediate.
/// Registry access only — no decisions; those live in `CollectorMapping`.
enum IOKitRegistryReader {

    static func readUSBDevice(_ service: io_service_t) -> IORegistryUSBDevice {
        let locationID = intProperty(service, "locationID")
        return IORegistryUSBDevice(
            idVendor: intProperty(service, "idVendor") ?? 0,
            idProduct: intProperty(service, "idProduct") ?? 0,
            usbSerialNumber: stringProperty(service, "USB Serial Number"),
            usbVendorName: stringProperty(service, "USB Vendor Name") ?? stringProperty(service, "kUSBVendorString"),
            usbProductName: stringProperty(service, "USB Product Name") ?? stringProperty(service, "kUSBProductString"),
            locationID: locationID,
            portPath: locationID.map(CollectorMapping.portPath(fromLocationID:)),
            interfaces: readInterfaces(of: service)
        )
    }

    /// Walks the device's children for IOUSBHostInterface entries, in
    /// configuration order (bInterfaceNumber when present, walk order otherwise).
    private static func readInterfaces(of device: io_service_t) -> [IORegistryUSBInterface] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var raw: [(number: Int?, triple: (Int, Int, Int))] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { continue }
            raw.append((
                number: intProperty(child, "bInterfaceNumber"),
                triple: (
                    intProperty(child, "bInterfaceClass") ?? 0,
                    intProperty(child, "bInterfaceSubClass") ?? 0,
                    intProperty(child, "bInterfaceProtocol") ?? 0
                )
            ))
        }
        return raw
            .enumerated()
            .sorted { ($0.element.number ?? $0.offset) < ($1.element.number ?? $1.offset) }
            .enumerated()
            .map { seq, entry in
                IORegistryUSBInterface(
                    seq: seq,
                    bInterfaceClass: entry.element.triple.0,
                    bInterfaceSubClass: entry.element.triple.1,
                    bInterfaceProtocol: entry.element.triple.2
                )
            }
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? String
    }
}
