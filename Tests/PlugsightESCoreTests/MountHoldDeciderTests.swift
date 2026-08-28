// MountHoldDeciderTests.swift
//
// N12 (07): the AUTH_MOUNT hold decision is a PURE function over
// (policyCache, deviceTrust, volumeDeviceKey, freshness) -> allow/deny.
// CRITICAL (02): FAIL-OPEN — any cache miss, staleness, absence, or error
// answers ALLOW. DENY happens in exactly one case: hold policy ON, cache
// FRESH, device PRESENT in the cache, and its tier is not `.trusted`.

import XCTest
import PlugsightCore
@testable import PlugsightESCore

final class MountHoldDeciderTests: XCTestCase {

    // Fixed clock so every freshness assertion is deterministic.
    let now = Date(timeIntervalSince1970: 1_756_000_000)

    func freshCache(
        hold: Bool = true,
        trust: [String: TrustTier] = ["serial:1452:591:ABC123": .none],
        bsdMap: [String: String] = ["disk4": "serial:1452:591:ABC123"],
        age: TimeInterval = 5
    ) -> ESPolicySnapshot {
        ESPolicySnapshot(
            holdUntilScanned: hold,
            trustByDeviceKey: trust,
            bsdNameToDeviceKey: bsdMap,
            pushedAt: now.addingTimeInterval(-age)
        )
    }

    // MARK: - The one DENY case

    func testUntrustedDeviceFreshCacheHoldOnDenies() {
        let decision = MountHoldDecider.decide(
            cache: freshCache(),
            volumeDeviceKey: "serial:1452:591:ABC123",
            now: now
        )
        XCTAssertEqual(decision, .deny(.untrustedHold))
    }

    func testFlaggedTierIsUntrustedForMounting() {
        let cache = freshCache(trust: ["k": .flagged])
        XCTAssertEqual(
            MountHoldDecider.decide(cache: cache, volumeDeviceKey: "k", now: now),
            .deny(.untrustedHold)
        )
    }

    func testMutedTierIsUntrustedForMounting() {
        // Muted silences NOTIFICATIONS (05); it does not confer trust. Only
        // `.trusted` exempts a device from the hold.
        let cache = freshCache(trust: ["k": .muted])
        XCTAssertEqual(
            MountHoldDecider.decide(cache: cache, volumeDeviceKey: "k", now: now),
            .deny(.untrustedHold)
        )
    }

    // MARK: - ALLOW paths (each with its honest reason)

    func testTrustedDeviceAllows() {
        let cache = freshCache(trust: ["k": .trusted])
        XCTAssertEqual(
            MountHoldDecider.decide(cache: cache, volumeDeviceKey: "k", now: now),
            .allow(.trustedDevice)
        )
    }

    func testHoldPolicyOffAllows() {
        let cache = freshCache(hold: false)
        XCTAssertEqual(
            MountHoldDecider.decide(
                cache: cache, volumeDeviceKey: "serial:1452:591:ABC123", now: now
            ),
            .allow(.holdDisabled)
        )
    }

    // MARK: - FAIL-OPEN (02): any miss/error/staleness -> ALLOW

    func testCacheAbsentFailsOpen() {
        XCTAssertEqual(
            MountHoldDecider.decide(cache: nil, volumeDeviceKey: "k", now: now),
            .allow(.cacheAbsent)
        )
    }

    func testStaleCacheFailsOpen() {
        let cache = freshCache(age: ESDefaults.policyTTL + 1)
        XCTAssertEqual(
            MountHoldDecider.decide(
                cache: cache, volumeDeviceKey: "serial:1452:591:ABC123", now: now
            ),
            .allow(.cacheStale)
        )
    }

    func testCacheMissOnDeviceKeyFailsOpen() {
        XCTAssertEqual(
            MountHoldDecider.decide(
                cache: freshCache(), volumeDeviceKey: "serial:9999:9999:NOPE", now: now
            ),
            .allow(.unknownDevice)
        )
    }

    func testNilDeviceKeyFailsOpen() {
        // The plumbing could not resolve the mounting volume to a device key
        // (resolution error). Errors ALLOW, never DENY.
        XCTAssertEqual(
            MountHoldDecider.decide(cache: freshCache(), volumeDeviceKey: nil, now: now),
            .allow(.unknownDevice)
        )
    }

    func testEveryAllowReasonIsAllowAndDenyIsDeny() {
        // The verdict enum itself: isDeny is true for .deny only. The plumbing
        // maps isDeny straight onto ES_AUTH_RESULT_DENY.
        XCTAssertTrue(ESAuthDecision.deny(.untrustedHold).isDeny)
        XCTAssertFalse(ESAuthDecision.allow(.cacheAbsent).isDeny)
    }

    // MARK: - Freshness boundary

    func testFreshnessBoundaryIsInclusive() {
        // Exactly at TTL -> still fresh; one second past -> stale.
        let atTTL = freshCache(age: ESDefaults.policyTTL)
        XCTAssertTrue(atTTL.isFresh(now: now, ttl: ESDefaults.policyTTL))
        let past = freshCache(age: ESDefaults.policyTTL + 1)
        XCTAssertFalse(past.isFresh(now: now, ttl: ESDefaults.policyTTL))
    }

    func testFutureTimestampCountsAsFresh() {
        // Clock skew must not brick mounting: a pushedAt slightly in the
        // future is fresh, not an error.
        let cache = freshCache(age: -3)
        XCTAssertTrue(cache.isFresh(now: now, ttl: ESDefaults.policyTTL))
    }

    // MARK: - BSD-name -> device-key resolution (pure, used by the plumbing)

    func testResolvesExactBSDName() {
        XCTAssertEqual(
            freshCache().deviceKey(forBSDName: "disk4"),
            "serial:1452:591:ABC123"
        )
    }

    func testResolvesSliceToWholeDisk() {
        // A mount arrives for the slice (disk4s1); the daemon pushed the map
        // keyed by whole disk (disk4).
        XCTAssertEqual(
            freshCache().deviceKey(forBSDName: "disk4s1"),
            "serial:1452:591:ABC123"
        )
    }

    func testStripsDevPrefix() {
        XCTAssertEqual(
            freshCache().deviceKey(forBSDName: "/dev/disk4s1"),
            "serial:1452:591:ABC123"
        )
    }

    func testUnknownBSDNameResolvesNil() {
        XCTAssertNil(freshCache().deviceKey(forBSDName: "disk9"))
        XCTAssertNil(freshCache().deviceKey(forBSDName: ""))
    }

    // MARK: - ESPolicyCacheBox (thread-safe holder the plumbing reads)

    func testCacheBoxStartsEmptyAndHoldsLatestSnapshot() {
        let box = ESPolicyCacheBox()
        XCTAssertNil(box.snapshot)
        let first = freshCache(age: 10)
        box.update(first)
        XCTAssertEqual(box.snapshot, first)
        let second = freshCache(age: 0)
        box.update(second)
        XCTAssertEqual(box.snapshot, second)
    }
}
