// DiskAppearanceWatcher.swift
//
// THIN DiskArbitration plumbing for the ES policy pusher (02, 05): report
// every disk (whole disk and slices) the moment it APPEARS — before any
// mount — with its owning USB device's collector key, so the pusher can get
// the BSD-name map to the extension ahead of the AUTH_MOUNT that follows
// insertion. DiskArbitrationSource cannot serve this: it deliberately speaks
// only when a volume PATH appears (mount ground truth), which is after the
// AUTH decision.
//
// Best effort by design: if the push loses the race with the kernel's
// auto-mount, the decider answers allow(unknownDevice) — fail-open, recorded.
// Cannot run in CI (needs real disks); the pusher's map handling is pure and
// tested with injected calls.

import DiskArbitration
import Foundation

public final class DiskAppearanceWatcher: @unchecked Sendable {

    /// (bsdName, collectorDeviceKey) when a USB-owned disk appears.
    public var onAppear: (@Sendable (String, String) -> Void)?
    /// bsdName when any previously seen disk disappears.
    public var onGone: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "plugsight.disk-appearance-watcher")
    private var session: DASession?
    /// Disks announced via onAppear, so onGone only fires for them.
    private var announced: Set<String> = []

    public init() {}

    deinit { stop() }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, refcon in
            guard let refcon else { return }
            Unmanaged<DiskAppearanceWatcher>.fromOpaque(refcon).takeUnretainedValue().handleAppeared(disk)
        }, refcon)

        DARegisterDiskDisappearedCallback(session, nil, { disk, refcon in
            guard let refcon else { return }
            Unmanaged<DiskAppearanceWatcher>.fromOpaque(refcon).takeUnretainedValue().handleGone(disk)
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
    }

    private func handleAppeared(_ disk: DADisk) {
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }),
              let deviceKey = USBDiskAncestry.collectorDeviceKey(forDisk: disk) else { return }
        lock.lock()
        announced.insert(bsdName)
        lock.unlock()
        onAppear?(bsdName, deviceKey)
    }

    private func handleGone(_ disk: DADisk) {
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        lock.lock()
        let wasAnnounced = announced.remove(bsdName) != nil
        lock.unlock()
        guard wasAnnounced else { return }
        onGone?(bsdName)
    }
}
