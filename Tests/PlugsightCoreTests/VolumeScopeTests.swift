// VolumeScopeTests.swift
//
// The pure volume-scope predicates (Wave 1b): which mounted volumes Plugsight
// tracks at all (the ddcb42a scan-on-mount fix), and which volume PATHS belong
// to macOS itself (used by the store's one-time cleanup of historical failed
// scan rows). One predicate in PlugsightCore, no IOKit/DiskArbitration imports.

import XCTest
@testable import PlugsightCore

final class VolumeScopeTests: XCTestCase {

    // MARK: - Flags predicate (mirrors the ddcb42a rule)

    func testInternalAndNetworkVolumesAreNotTrackable() {
        XCTAssertFalse(VolumeScope.isTrackableVolume(isInternal: true, isNetwork: false))
        XCTAssertFalse(VolumeScope.isTrackableVolume(isInternal: true, isNetwork: nil))
        XCTAssertFalse(VolumeScope.isTrackableVolume(isInternal: false, isNetwork: true))
    }

    func testExternalVolumesAreTrackable() {
        XCTAssertTrue(VolumeScope.isTrackableVolume(isInternal: false, isNetwork: false))
        // Absent flags must NOT drop a real external drive (fail open to tracking).
        XCTAssertTrue(VolumeScope.isTrackableVolume(isInternal: nil, isNetwork: nil))
    }

    // MARK: - Path predicate (historical rows only carry the path)

    func testAppleSystemVolumePathsAreInternal() {
        for name in ["Preboot", "VM", "xarts", "iSCPreboot", "Hardware", "Update", "Recovery", "Data"] {
            XCTAssertTrue(VolumeScope.isInternalSystemVolumePath("/System/Volumes/\(name)"),
                          "/System/Volumes/\(name) is macOS's own storage")
        }
        XCTAssertTrue(VolumeScope.isInternalSystemVolumePath("/"), "the boot volume is internal")
    }

    func testUserVolumePathsAreNotInternal() {
        XCTAssertFalse(VolumeScope.isInternalSystemVolumePath("/Volumes/STICK"))
        // A user drive that HAPPENS to carry a system volume name stays a user drive.
        XCTAssertFalse(VolumeScope.isInternalSystemVolumePath("/Volumes/Update"))
        XCTAssertFalse(VolumeScope.isInternalSystemVolumePath("/Volumes/Preboot"))
        // Prefix must be the real /System/Volumes directory, not a lookalike.
        XCTAssertFalse(VolumeScope.isInternalSystemVolumePath("/System/VolumesX/Preboot"))
    }
}
