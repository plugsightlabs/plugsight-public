// VolumeRemounting.swift
//
// The mount/unmount seam for the hold flow (05): the pure sequencing
// (MountHoldFlow) and the coordinator are tested against a double; this file
// holds the seam protocol and the DiskArbitration implementation the live
// daemon uses.
//
// NEEDS LIVE VERIFICATION: the DiskArbitration calls below are the
// best-documented mechanism (DADiskMountWithArguments with a "nobrowse"
// argument for the private scan mount; a default DADiskMount for the
// user-visible remount), but they CANNOT be exercised end to end on this
// machine until the ES entitlement lands, because the deny that precedes
// them never fires without the extension. The manual dev-machine session
// (ESExtension/README.md step 3) is the gate that proves them.

import DiskArbitration
import Foundation

/// What the hold flow needs from the mount layer. Every call is synchronous
/// from the caller's view (the coordinator invokes them off the event queue).
public protocol VolumeRemounting: Sendable {
    /// Mount the volume nobrowse (invisible to Finder) at a private location.
    /// Returns the mount path.
    func mountPrivate(bsdName: String) throws -> String
    /// Unmount the private mount (best effort).
    func unmountPrivate(bsdName: String)
    /// Request the normal, user-visible mount. Best effort: the observed
    /// browseable mount, not this call's return, is what releases the hold.
    func remountUserVisible(bsdName: String) throws
}

public enum RemountError: Error, Equatable {
    case sessionUnavailable
    case diskUnavailable(String)
    case mountFailed(String)
    case timedOut(String)
}

/// DiskArbitration-backed implementation. Serializes each operation with a
/// semaphore over the DA callback; a hard timeout keeps the hold flow's
/// fail-open guarantee even if diskarbitrationd never answers.
public final class DiskArbitrationRemounter: VolumeRemounting, @unchecked Sendable {

    private let queue = DispatchQueue(label: "plugsight.hold-remounter")
    private let privateMountRoot: String
    private let timeout: TimeInterval

    /// - Parameter privateMountRoot: directory under which per-volume private
    ///   mountpoints are created (state dir; 0700).
    public init(privateMountRoot: String, timeout: TimeInterval = 30) {
        self.privateMountRoot = privateMountRoot
        self.timeout = timeout
    }

    public func mountPrivate(bsdName: String) throws -> String {
        let mountPath = (privateMountRoot as NSString).appendingPathComponent(bsdName)
        try FileManager.default.createDirectory(
            atPath: mountPath, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // "nobrowse": the mount never appears in Finder, and the extension's
        // decider explicitly allows nobrowse mounts (the flow's own scan
        // mount must not be re-denied).
        try mount(bsdName: bsdName, at: URL(fileURLWithPath: mountPath), arguments: ["nobrowse"])
        return mountPath
    }

    public func unmountPrivate(bsdName: String) {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return }
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        let done = DispatchSemaphore(value: 0)
        let holder = CallbackHolder { _ in done.signal() }
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, context in
            guard let context else { return }
            Unmanaged<CallbackHolder>.fromOpaque(context).takeUnretainedValue().finish(dissenter)
        }, Unmanaged.passUnretained(holder).toOpaque())
        _ = done.wait(timeout: .now() + timeout)
        withExtendedLifetime(holder) {}
    }

    public func remountUserVisible(bsdName: String) throws {
        try mount(bsdName: bsdName, at: nil, arguments: [])
    }

    // MARK: - The one DA mount wrapper

    private func mount(bsdName: String, at url: URL?, arguments: [String]) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw RemountError.sessionUnavailable
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw RemountError.diskUnavailable(bsdName)
        }
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }

        let done = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()
        let holder = CallbackHolder { dissenter in
            resultBox.dissenter = dissenter
            done.signal()
        }

        // NULL-terminated vector of CFString mount options, as the Swift
        // signature of DADiskMountWithArguments expects.
        var argv: [Unmanaged<CFString>?] = arguments.map { Unmanaged.passRetained($0 as CFString) }
        argv.append(nil)
        defer { for arg in argv { arg?.release() } }

        argv.withUnsafeMutableBufferPointer { buffer in
            DADiskMountWithArguments(
                disk, url as CFURL?,
                DADiskMountOptions(kDADiskMountOptionDefault),
                { _, dissenter, context in
                    guard let context else { return }
                    Unmanaged<CallbackHolder>.fromOpaque(context).takeUnretainedValue().finish(dissenter)
                },
                Unmanaged.passUnretained(holder).toOpaque(),
                buffer.baseAddress
            )
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw RemountError.timedOut(bsdName)
        }
        withExtendedLifetime(holder) {}
        if let dissenter = resultBox.dissenter {
            let status = DADissenterGetStatus(dissenter)
            throw RemountError.mountFailed("\(bsdName): DA status \(status)")
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var dissenter: DADissenter?
    }

    private final class CallbackHolder {
        let onFinish: (DADissenter?) -> Void
        init(_ onFinish: @escaping (DADissenter?) -> Void) { self.onFinish = onFinish }
        func finish(_ dissenter: DADissenter?) { onFinish(dissenter) }
    }
}
