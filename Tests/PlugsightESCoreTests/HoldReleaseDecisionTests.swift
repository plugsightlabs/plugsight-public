// HoldReleaseDecisionTests.swift
//
// The two decision extensions the LIVE hold flow needs (05):
//
//  1. `scanCleared`: after a clean scan the daemon marks the device cleared in
//     the pushed snapshot, so the user-visible REMOUNT (and any manual mount
//     until the clearance is withdrawn) is allowed. Without this the daemon's
//     own remount would be denied again and the flow could never release.
//  2. `nobrowseMount`: the daemon's PRIVATE scan remount is mounted nobrowse;
//     a nobrowse mount is exempt from the hold, because the hold protects the
//     user-visible auto-mount, and denying our own private mount would
//     deadlock the scan. A nobrowse mount never appears in Finder.
//
// Both are ALLOW reasons: they widen fail-open, never narrow it.

import XCTest
import PlugsightCore
@testable import PlugsightESCore

final class HoldReleaseDecisionTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_756_000_000)
    let key = "serial:1452:591:ABC123"

    func cache(
        hold: Bool = true,
        tier: TrustTier = .none,
        cleared: Set<String> = [],
        age: TimeInterval = 5
    ) -> ESPolicySnapshot {
        ESPolicySnapshot(
            holdUntilScanned: hold,
            trustByDeviceKey: [key: tier],
            bsdNameToDeviceKey: ["disk4": key],
            pushedAt: now.addingTimeInterval(-age),
            clearedDeviceKeys: cleared
        )
    }

    // MARK: - scanCleared

    func testClearedDeviceAllowsAfterCleanScan() {
        let decision = MountHoldDecider.decide(
            cache: cache(cleared: [key]), volumeDeviceKey: key, now: now
        )
        XCTAssertEqual(decision, .allow(.scanCleared))
    }

    func testUnclearedDeviceStillDenies() {
        let decision = MountHoldDecider.decide(
            cache: cache(cleared: ["some-other-device"]), volumeDeviceKey: key, now: now
        )
        XCTAssertEqual(decision, .deny(.untrustedHold))
    }

    func testClearanceDoesNotOutrankStaleness() {
        // Stale cache fails open with its own reason: the clearance never
        // masks the fail-open story in the log.
        let decision = MountHoldDecider.decide(
            cache: cache(cleared: [key], age: 120), volumeDeviceKey: key, now: now
        )
        XCTAssertEqual(decision, .allow(.cacheStale))
    }

    func testTrustedReasonWinsOverClearance() {
        // A trusted device reads `trustedDevice`, not `scanCleared` — the log
        // should name the strongest standing fact.
        let decision = MountHoldDecider.decide(
            cache: cache(tier: .trusted, cleared: [key]), volumeDeviceKey: key, now: now
        )
        XCTAssertEqual(decision, .allow(.trustedDevice))
    }

    // MARK: - nobrowseMount (the private scan remount)

    func testNobrowseMountAllowsEvenForHeldDevice() {
        let decision = MountHoldDecider.decide(
            cache: cache(), volumeDeviceKey: key, now: now, nobrowse: true
        )
        XCTAssertEqual(decision, .allow(.nobrowseMount))
    }

    func testNobrowseAllowsEvenForUnknownDevice() {
        let decision = MountHoldDecider.decide(
            cache: cache(), volumeDeviceKey: nil, now: now, nobrowse: true
        )
        XCTAssertEqual(decision, .allow(.nobrowseMount))
    }

    func testNobrowseDefaultsToFalseKeepingTheDeny() {
        let decision = MountHoldDecider.decide(
            cache: cache(), volumeDeviceKey: key, now: now
        )
        XCTAssertEqual(decision, .deny(.untrustedHold))
    }

    func testDeadlineExhaustionStillPreemptsEverything() {
        let budget = ESDeadlineBudget(deadline: now.addingTimeInterval(0.5))
        let decision = MountHoldDecider.decide(
            cache: cache(), volumeDeviceKey: key, now: now, budget: budget, nobrowse: true
        )
        XCTAssertEqual(decision, .allow(.deadlineExhausted))
    }

    // MARK: - Wire tolerance

    func testSnapshotWithoutClearedKeysStillDecodes() throws {
        // A payload from a build that predates clearedDeviceKeys must decode
        // (absent = nothing cleared), so a version skew never drops the cache.
        let json = """
        {"bsdNameToDeviceKey":{"disk4":"\(key)"},"holdUntilScanned":true,
         "pushedAt":1756000000,"trustByDeviceKey":{"\(key)":"none"}}
        """
        let snapshot = try ESWire.decode(ESPolicySnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.clearedDeviceKeys, [])
        XCTAssertTrue(snapshot.holdUntilScanned)
    }

    func testClearedKeysRoundTripOnTheWire() throws {
        let snapshot = cache(cleared: [key])
        let back = try ESWire.decode(ESPolicySnapshot.self, from: ESWire.encode(snapshot))
        XCTAssertEqual(back, snapshot)
    }

    func testObservedEventNobrowseRoundTripsAndDefaultsNil() throws {
        let event = ESObservedEvent(
            kind: .mount, timestamp: now, bsdName: "disk4s1",
            mountPath: "/Volumes/UNTITLED", nobrowse: true
        )
        let back = try ESWire.decode(ESObservedEvent.self, from: ESWire.encode(event))
        XCTAssertEqual(back.nobrowse, true)

        let bare = ESObservedEvent(kind: .unmount, timestamp: now)
        let bareBack = try ESWire.decode(ESObservedEvent.self, from: ESWire.encode(bare))
        XCTAssertNil(bareBack.nobrowse)
    }
}
