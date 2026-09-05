// VolumeScope.swift
//
// The PURE volume-scope rules: Plugsight watches drives the user PLUGS IN,
// never the Mac's own storage. Two predicates, one home:
//
//   - `isTrackableVolume(isInternal:isNetwork:)` — the live Disk Arbitration
//     rule (commit ddcb42a): internal system media and network mounts never
//     enter the pipeline.
//   - `isInternalSystemVolumePath(_:)` — the same scope expressed over a bare
//     volume PATH, for historical rows that only carry the path (the store's
//     one-time cleanup of "Scan of xarts failed" junk recorded before ddcb42a).
//
// This lives in PlugsightCore (seam rule: NO IOKit / DiskArbitration imports
// here) so the collector and the store share ONE predicate instead of two
// drifting copies. The collector passes the DADisk description flags in; this
// file never touches Disk Arbitration itself.

public enum VolumeScope {

    /// A volume is trackable (a drive the user plugged in) only when it is
    /// NEITHER internal system media NOR a network mount. Absent flags (nil) are
    /// treated as "not internal / not network", so a real external drive is
    /// never dropped; internal system volumes always report DeviceInternal ==
    /// true. Pure, so the scope rule is unit-tested even though the live Disk
    /// Arbitration source cannot run in CI.
    public static func isTrackableVolume(isInternal: Bool?, isNetwork: Bool?) -> Bool {
        isInternal != true && isNetwork != true
    }

    /// True when `path` is macOS's own storage rather than a user-plugged
    /// drive: the boot volume ("/") or anything under /System/Volumes — the
    /// Apple APFS system volumes (Preboot, VM, xarts, iSCPreboot, Hardware,
    /// Update, Recovery, Data). Deliberately conservative: a user drive that
    /// happens to carry a system-volume NAME mounts under /Volumes and stays
    /// out of this set, so no user data is ever cleaned up by name alone.
    public static func isInternalSystemVolumePath(_ path: String) -> Bool {
        path == "/" || path == "/System/Volumes" || path.hasPrefix("/System/Volumes/")
    }
}
