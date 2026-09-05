// ESPolicyPusherTests.swift
//
// The snapshot assembly the extension's AUTH_MOUNT decision depends on:
// hold flag from policy, trust table from the store, BSD map from disk
// appearance (resolved lazily, because the analyzer may not have upserted the
// device yet), clearances added after clean hold-scans and WITHDRAWN when the
// disk goes away (a re-plug is held again, 05).

import XCTest
import PlugsightCore
import PlugsightESCore
@testable import PlugsightDaemon

final class ESPolicyPusherTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var snapshots: [ESPolicySnapshot] = []
        func record(_ s: ESPolicySnapshot) {
            lock.lock(); snapshots.append(s); lock.unlock()
        }
        var last: ESPolicySnapshot? {
            lock.lock(); defer { lock.unlock() }
            return snapshots.last
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return snapshots.count
        }
    }

    private func makePusher(
        hold: Bool = true,
        trust: [String: TrustTier] = ["identity-A": .none],
        identities: [String: String] = ["collector-A": "identity-A"],
        recorder: Recorder
    ) -> ESPolicyPusher {
        ESPolicyPusher(
            holdPolicyProvider: { hold },
            trustProvider: { trust },
            identityResolver: { identities[$0] },
            send: { recorder.record($0) }
        )
    }

    func testSnapshotCarriesPolicyTrustAndResolvedDisks() {
        let recorder = Recorder()
        let pusher = makePusher(recorder: recorder)
        pusher.diskAppeared(bsdName: "disk4", collectorDeviceKey: "collector-A")

        let snapshot = pusher.currentSnapshot()
        XCTAssertTrue(snapshot.holdUntilScanned)
        XCTAssertEqual(snapshot.trustByDeviceKey["identity-A"], TrustTier.none)
        XCTAssertEqual(snapshot.bsdNameToDeviceKey["disk4"], "identity-A")
        XCTAssertEqual(snapshot.clearedDeviceKeys, [])
        XCTAssertEqual(recorder.count, 1, "disk appearance pushes immediately")
    }

    func testUnresolvedDiskIsOmittedThenRetriedOnLaterPushes() {
        let recorder = Recorder()
        let identities = IdentityBox()
        let pusher = ESPolicyPusher(
            holdPolicyProvider: { true },
            trustProvider: { [:] },
            identityResolver: { identities.lookup($0) },
            send: { recorder.record($0) }
        )
        pusher.diskAppeared(bsdName: "disk4", collectorDeviceKey: "collector-A")
        XCTAssertNil(recorder.last?.bsdNameToDeviceKey["disk4"],
                     "an unresolvable device is omitted (decider fails open on the miss)")

        // The analyzer catches up (device upserted); the next push resolves.
        identities.set("collector-A", to: "identity-A")
        pusher.pushNow()
        XCTAssertEqual(recorder.last?.bsdNameToDeviceKey["disk4"], "identity-A")
    }

    func testClearanceIsPushedImmediatelyAndWithdrawnOnDiskGone() {
        let recorder = Recorder()
        let pusher = makePusher(recorder: recorder)
        pusher.diskAppeared(bsdName: "disk4", collectorDeviceKey: "collector-A")

        pusher.markCleared(identityKey: "identity-A")
        XCTAssertEqual(recorder.last?.clearedDeviceKeys, ["identity-A"],
                       "a clean hold-scan clearance must reach the extension at once")

        pusher.diskGone(bsdName: "disk4")
        XCTAssertEqual(recorder.last?.clearedDeviceKeys, [],
                       "unplugging withdraws the clearance so a re-plug is held again")
        XCTAssertNil(recorder.last?.bsdNameToDeviceKey["disk4"])
    }

    func testHeartbeatKeepsPushingFreshSnapshots() async throws {
        let recorder = Recorder()
        let pusher = ESPolicyPusher(
            holdPolicyProvider: { true },
            trustProvider: { [:] },
            identityResolver: { _ in nil },
            send: { recorder.record($0) },
            heartbeatInterval: 0.05
        )
        pusher.startHeartbeat()
        defer { pusher.stopHeartbeat() }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThanOrEqual(recorder.count, 2,
                                    "the heartbeat must re-push well inside the TTL")
    }

    private final class IdentityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: String] = [:]
        func set(_ key: String, to value: String) {
            lock.lock(); map[key] = value; lock.unlock()
        }
        func lookup(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return map[key]
        }
    }
}
