// DiskArbitrationSource.swift
//
// THIN live plumbing (docs/spec/02): DiskArbitration is the mount/unmount
// ground truth in the base build. Disk appearance/description-change/
// disappearance callbacks are reduced to the pure `DiskArbitrationVolume`
// intermediate (the owning USB device resolved to the same deviceKey the
// IOKitDeviceSource derives, by walking the disk's IORegistry ancestry to the
// IOUSBHostDevice and reusing `CollectorMapping.deviceKey`), then mapped by
// `CollectorMapping.volumeEvent` and yielded.
//
// Cannot run in CI (needs a real disk mount); exercised by the manual probe
// `ops/dev-attach-probe.swift`.

import Foundation
import DiskArbitration
import IOKit
import PlugsightCore

public final class DiskArbitrationSource: DeviceEventSource, @unchecked Sendable {

    public var events: AsyncStream<CollectorEvent> { stream }

    private let stream: AsyncStream<CollectorEvent>
    private let continuation: AsyncStream<CollectorEvent>.Continuation

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "plugsight.diskarbitration-source")
    private var session: DASession?
    /// BSD name -> last known (deviceKey, volumePath), so unmount/disappear can
    /// name the volume after DiskArbitration has forgotten the path.
    private var mountedByBSDName: [String: (deviceKey: String, volumePath: String)] = [:]

    public init() {
        var continuation: AsyncStream<CollectorEvent>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw CollectorSourceError.diskArbitrationSessionUnavailable
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Appeared with a volume path (e.g. already mounted at daemon start).
        DARegisterDiskAppearedCallback(session, nil, { disk, refcon in
            guard let refcon else { return }
            Unmanaged<DiskArbitrationSource>.fromOpaque(refcon).takeUnretainedValue().handleDiskUpdate(disk)
        }, refcon)

        // Volume path appearing/disappearing == mount/unmount ground truth.
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            [kDADiskDescriptionVolumePathKey] as CFArray,
            { disk, _, refcon in
                guard let refcon else { return }
                Unmanaged<DiskArbitrationSource>.fromOpaque(refcon).takeUnretainedValue().handleDiskUpdate(disk)
            },
            refcon
        )

        // Physical removal while mounted (yank): emit the unmount.
        DARegisterDiskDisappearedCallback(session, nil, { disk, refcon in
            guard let refcon else { return }
            Unmanaged<DiskArbitrationSource>.fromOpaque(refcon).takeUnretainedValue().handleDiskGone(disk)
        }, refcon)

        DASessionSetDispatchQueue(session, queue)
        self.session = session
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
        continuation.finish()
    }

    // MARK: - Callbacks (thin: reduce, map via pure functions, yield)

    private func handleDiskUpdate(_ disk: DADisk) {
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        let description = DADiskCopyDescription(disk) as? [CFString: Any] ?? [:]
        let volumePath = (description[kDADiskDescriptionVolumePathKey] as? URL)?.path

        lock.lock()
        let previous = mountedByBSDName[bsdName]
        lock.unlock()

        if let volumePath {
            guard previous?.volumePath != volumePath else { return } // no change
            let deviceKey = usbDeviceKey(forDisk: disk) ?? "disk-\(bsdName)"
            lock.lock()
            mountedByBSDName[bsdName] = (deviceKey, volumePath)
            lock.unlock()
            continuation.yield(CollectorMapping.volumeEvent(mounted: DiskArbitrationVolume(
                deviceKey: deviceKey,
                volumePath: volumePath,
                volumeName: description[kDADiskDescriptionVolumeNameKey] as? String,
                totalBytes: (description[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.intValue
            )))
        } else if let previous {
            lock.lock()
            mountedByBSDName.removeValue(forKey: bsdName)
            lock.unlock()
            continuation.yield(CollectorMapping.volumeEvent(
                unmountedDeviceKey: previous.deviceKey,
                volumePath: previous.volumePath,
                at: Date()
            ))
        }
    }

    private func handleDiskGone(_ disk: DADisk) {
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        lock.lock()
        let previous = mountedByBSDName.removeValue(forKey: bsdName)
        lock.unlock()
        guard let previous else { return }
        continuation.yield(CollectorMapping.volumeEvent(
            unmountedDeviceKey: previous.deviceKey,
            volumePath: previous.volumePath,
            at: Date()
        ))
    }

    /// Walks the disk's IORegistry ancestry to the owning IOUSBHostDevice and
    /// derives the SAME deviceKey the IOKitDeviceSource assigns, so volume
    /// events correlate with attach events for one physical device.
    private func usbDeviceKey(forDisk disk: DADisk) -> String? {
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
