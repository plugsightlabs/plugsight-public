#!/usr/bin/env swift
// dev-attach-probe.swift — the MANUAL N5 hardware gate.
//
// Prints live CollectorEvents (attached / detached, with the same fields and
// deviceKey derivation the daemon's IOKitDeviceSource emits) so a human can
// smoke-test the collector plumbing on real hardware.
//
// HOW TO RUN (real hardware, not CI):
//     cd <repo root>
//     swift ops/dev-attach-probe.swift          # or: chmod +x ops/dev-attach-probe.swift && ./ops/dev-attach-probe.swift
// Then plug a USB device in, wait for the "attached" line, and unplug it for
// the "detached" line. Ctrl-C to quit. Paste one attach/detach pair into the
// N5 PR description as the manual-gate evidence.
//
// This script is deliberately SELF-CONTAINED (no SPM target, no import of the
// daemon sources): it duplicates the tiny read/derive logic inline so it can
// run with `swift <file>` from a clean checkout. The authoritative, unit-tested
// mapping lives in Sources/PlugsightDaemon/Collector/CollectorMapping.swift —
// if the printed fields ever disagree with the daemon, trust the daemon and
// fix the probe.

import Foundation
import IOKit
import IOKit.usb

// Unbuffered stdout so events stream immediately when piped/teed to a log.
setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Registry reading (mirror of IOKitRegistryReader, kept tiny)

func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
    let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    return (value as? NSNumber)?.intValue
}

func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
    let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    return value as? String
}

func portPath(fromLocationID locationID: Int) -> String {
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

func deviceKey(locationID: Int?, vid: Int, pid: Int) -> String {
    if let locationID {
        return String(format: "usb-loc-0x%08x", UInt32(truncatingIfNeeded: locationID))
    }
    return "usb-vidpid-\(vid)-\(pid)"
}

func interfaceTriples(of device: io_service_t) -> [(Int, Int, Int)] {
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
    return raw.enumerated()
        .sorted { ($0.element.number ?? $0.offset) < ($1.element.number ?? $1.offset) }
        .map(\.element.triple)
}

// MARK: - Event printing

var keysByEntryID: [UInt64: String] = [:]

func describeQuoted(_ string: String?) -> String {
    guard let string else { return "nil" }
    // Junk-safe printing for a terminal: escape control chars, keep the rest raw.
    let escaped = string.unicodeScalars.map { scalar -> String in
        scalar.value < 0x20 || scalar.value == 0x7F
            ? String(format: "\\u{%02X}", scalar.value)
            : String(scalar)
    }.joined()
    return "\"\(escaped)\""
}

func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func handleAttach(_ iterator: io_iterator_t, quiet: Bool) {
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        let vid = intProperty(service, "idVendor") ?? 0
        let pid = intProperty(service, "idProduct") ?? 0
        let locationID = intProperty(service, "locationID")
        let key = deviceKey(locationID: locationID, vid: vid, pid: pid)
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        keysByEntryID[entryID] = key
        guard !quiet else { continue } // initial drain: arm only, stay silent
        let triples = interfaceTriples(of: service)
            .map { "(\($0.0),\($0.1),\($0.2))" }.joined(separator: " ")
        print("""
        [\(timestamp())] CollectorEvent.attached
            deviceKey:   \(key)
            vid/pid:     \(String(format: "0x%04X", vid))/\(String(format: "0x%04X", pid))
            serial:      \(describeQuoted(stringProperty(service, "USB Serial Number")))
            vendorName:  \(describeQuoted(stringProperty(service, "USB Vendor Name") ?? stringProperty(service, "kUSBVendorString")))
            productName: \(describeQuoted(stringProperty(service, "USB Product Name") ?? stringProperty(service, "kUSBProductString")))
            portPath:    \(locationID.map(portPath(fromLocationID:)) ?? "nil")
            interfaces:  [\(triples)]
        """)
    }
}

func handleDetach(_ iterator: io_iterator_t, quiet: Bool) {
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        let key = keysByEntryID.removeValue(forKey: entryID) ?? "unknown"
        guard !quiet else { continue }
        print("[\(timestamp())] CollectorEvent.detached  deviceKey: \(key)")
    }
}

// MARK: - Notification setup (same registrations as IOKitDeviceSource)

guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
    fputs("error: IONotificationPortCreate failed\n", stderr)
    exit(1)
}
IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

var quietDrain = true // suppress the flood of already-attached devices at startup

var matchedIterator: io_iterator_t = 0
let matchResult = IOServiceAddMatchingNotification(
    port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"),
    { _, iterator in handleAttach(iterator, quiet: false) },
    nil, &matchedIterator
)
guard matchResult == KERN_SUCCESS else {
    fputs("error: first-match registration failed (\(matchResult))\n", stderr)
    exit(1)
}
handleAttach(matchedIterator, quiet: quietDrain) // drain arms the notification

var terminatedIterator: io_iterator_t = 0
let termResult = IOServiceAddMatchingNotification(
    port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"),
    { _, iterator in handleDetach(iterator, quiet: false) },
    nil, &terminatedIterator
)
guard termResult == KERN_SUCCESS else {
    fputs("error: terminated registration failed (\(termResult))\n", stderr)
    exit(1)
}
handleDetach(terminatedIterator, quiet: quietDrain)
quietDrain = false

print("dev-attach-probe: watching IOUSBHostDevice first-match/terminated.")
print("Plug a USB device in / pull it out; Ctrl-C to quit.")
dispatchMain()
