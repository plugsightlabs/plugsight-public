// USBDiskAncestry.swift
//
// ONE place for the disk -> owning-USB-device walk: from a DADisk's IOMedia,
// climb the IORegistry ancestry to the IOUSBHostDevice and derive the SAME
// collector deviceKey the IOKitDeviceSource assigns, so volume and disk
// events correlate with attach events for one physical device. Used by the
// mount ground truth (DiskArbitrationSource) and by the ES policy pusher's
// disk-appearance watcher (the AUTH_MOUNT BSD-name map).
//
// THIN live plumbing: cannot run in CI (needs a real disk); every consumer's
// decisions are pure and tested against injected maps.

import DiskArbitration
import Foundation
import IOKit

enum USBDiskAncestry {
    /// The collector deviceKey for the USB device owning `disk`, or nil when
    /// the disk has no IOUSBHostDevice ancestor (internal media, disk images).
    static func collectorDeviceKey(forDisk disk: DADisk) -> String? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        var entry: io_registry_entry_t = media
        IOObjectRetain(entry)
        while true {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            if IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 {
                defer { IOObjectRelease(parent) }
                return CollectorMapping.deviceKey(for: IOKitRegistryReader.readUSBDevice(parent))
            }
            entry = parent
        }
    }
}
