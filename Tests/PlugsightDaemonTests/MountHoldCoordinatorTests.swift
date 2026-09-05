// MountHoldCoordinatorTests.swift
//
// The hold flow executed end to end against a real store and doubled mount /
// scan seams: extension events in, volume.held / volume.released rows (with
// the plain-language summaries) out, clearance pushed BEFORE the remount,
// infected kept held. The DiskArbitration remounter itself is live plumbing
// gated by the manual dev-machine session.

import XCTest
import PlugsightCore
import PlugsightESCore
@testable import PlugsightDaemon

private final class FakeRemounter: VolumeRemounting, @unchecked Sendable {
    let lock = NSLock()
    var privateMounts: [String] = []
    var privateUnmounts: [String] = []
    var userVisibleRemounts: [String] = []
    var privateMountFails = false
    var privatePathPrefix = "/tmp/holdscan"

    func mountPrivate(bsdName: String) throws -> String {
        lock.lock(); privateMounts.append(bsdName); let fails = privateMountFails; lock.unlock()
        if fails { throw RemountError.mountFailed(bsdName) }
        return "\(privatePathPrefix)/\(bsdName)"
    }

    func unmountPrivate(bsdName: String) {
        lock.lock(); privateUnmounts.append(bsdName); lock.unlock()
    }

    func remountUserVisible(bsdName: String) throws {
        lock.lock(); userVisibleRemounts.append(bsdName); lock.unlock()
    }

    var remountedBSDNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return userVisibleRemounts
    }
}

final class MountHoldCoordinatorTests: XCTestCase {

    private var store: EventStore!
    private var remounter: FakeRemounter!
    private var clearedLog: Locked<[String]>!
    private var scanRequests: Locked<[ScanRequest]>!

    private final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
        func append<E>(_ element: E) where T == [E] {
            lock.lock(); stored.append(element); lock.unlock()
        }
    }

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try EventStore(path: dir.appendingPathComponent("plugsight.db").path)
        remounter = FakeRemounter()
        clearedLog = Locked([])
        scanRequests = Locked([])
    }

    private func makeCoordinator(
        scanState: ScanState? = .clean,
        device: MountHoldCoordinator.DeviceRef? = .init(identityKey: "identity-A", deviceID: nil)
    ) -> MountHoldCoordinator {
        let scanRequests = self.scanRequests!
        let clearedLog = self.clearedLog!
        return MountHoldCoordinator(
            store: store,
            remounter: remounter,
            runScan: { request in
                scanRequests.append(request)
                guard let scanState else { throw ScanError.scannerUnavailable(installFix: "brew install clamav") }
                return scanState
            },
            deviceForBSD: { _ in device },
            markCleared: { clearedLog.append($0) }
        )
    }

    private func denyEvent(_ bsd: String) -> ESObservedEvent {
        ESObservedEvent(kind: .authMountDecision, timestamp: Date(), bsdName: bsd,
                        decision: .deny(.untrustedHold))
    }

    private func browseableMount(_ bsd: String) -> ESObservedEvent {
        ESObservedEvent(kind: .mount, timestamp: Date(), bsdName: bsd,
                        mountPath: "/Volumes/UNTITLED", nobrowse: false)
    }

    private func waitForPhase(
        _ coordinator: MountHoldCoordinator, bsd: String,
        _ predicate: @escaping (MountHoldFlow.Phase?) -> Bool,
        timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(coordinator.phase(forBSDName: bsd)), Date() < deadline {
            usleep(20_000)
        }
        XCTAssertTrue(predicate(coordinator.phase(forBSDName: bsd)),
                      "phase is \(String(describing: coordinator.phase(forBSDName: bsd)))")
    }

    private func eventKinds() throws -> [String] {
        try store.listEvents(limit: 50).map(\.kind).reversed()
    }

    // MARK: - Clean path

    func testCleanScanReleasesWithPlainLanguageRecord() throws {
        let coordinator = makeCoordinator(scanState: .clean)
        coordinator.handle(denyEvent("disk4s1"))
        waitForPhase(coordinator, bsd: "disk4s1") { $0 == .awaitingRemount(.cleanScan) }

        // The clearance must be pushed before (or with) the remount request.
        XCTAssertEqual(clearedLog.value, ["identity-A"])
        let deadline = Date().addingTimeInterval(5)
        while remounter.remountedBSDNames.isEmpty, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(remounter.remountedBSDNames, ["disk4s1"])

        // The observed browseable mount releases.
        coordinator.handle(browseableMount("disk4s1"))
        coordinator.drain()
        XCTAssertNil(coordinator.phase(forBSDName: "disk4s1"))

        let events = try store.listEvents(limit: 50)
        let held = events.first { $0.kind == "volume.held" }
        let released = events.first { $0.kind == "volume.released" }
        XCTAssertEqual(held?.summary, "Drive held until scanned.")
        XCTAssertEqual(held?.severity, "notice")
        XCTAssertEqual(released?.summary, "Drive released after a clean scan.")
        XCTAssertEqual(released?.severity, "info")
        XCTAssertEqual(scanRequests.value.map(\.volumePath), ["/tmp/holdscan/disk4s1"],
                       "the scan runs against the PRIVATE mount")
    }

    func testPrivateNobrowseMountDoesNotRelease() throws {
        let coordinator = makeCoordinator(scanState: .clean)
        coordinator.handle(denyEvent("disk4s1"))
        waitForPhase(coordinator, bsd: "disk4s1") { $0 == .awaitingRemount(.cleanScan) }

        // Our own nobrowse scan mount must NOT count as the release.
        coordinator.handle(ESObservedEvent(
            kind: .mount, timestamp: Date(), bsdName: "disk4s1",
            mountPath: "/private/hold", nobrowse: true
        ))
        coordinator.drain()
        XCTAssertEqual(coordinator.phase(forBSDName: "disk4s1"), .awaitingRemount(.cleanScan))
        XCTAssertFalse(try eventKinds().contains("volume.released"))
    }

    // MARK: - Infected path

    func testInfectedScanKeepsHeldAndNeverClears() throws {
        let coordinator = makeCoordinator(scanState: .infected)
        coordinator.handle(denyEvent("disk4s1"))
        waitForPhase(coordinator, bsd: "disk4s1") { $0 == .heldInfected }

        XCTAssertEqual(clearedLog.value, [], "an infected device is never cleared")
        XCTAssertEqual(remounter.remountedBSDNames, [])
        XCTAssertTrue(try eventKinds().contains("volume.held"))
        XCTAssertFalse(try eventKinds().contains("volume.released"))
    }

    // MARK: - Fail-open twins

    func testUnrunnableScanReleasesFailOpenWithHonestSummary() throws {
        let coordinator = makeCoordinator(scanState: nil)   // scan throws
        coordinator.handle(denyEvent("disk4s1"))
        waitForPhase(coordinator, bsd: "disk4s1") { $0 == .awaitingRemount(.failOpen) }
        XCTAssertEqual(clearedLog.value, ["identity-A"],
                       "fail-open still clears so the remount's AUTH_MOUNT is allowed")

        coordinator.handle(browseableMount("disk4s1"))
        coordinator.drain()
        let released = try store.listEvents(limit: 50).first { $0.kind == "volume.released" }
        XCTAssertEqual(released?.summary, "Drive released without a completed scan.")
        XCTAssertEqual(released?.severity, "notice")
    }

    func testPrivateMountFailureReleasesFailOpen() throws {
        remounter.privateMountFails = true
        let coordinator = makeCoordinator(scanState: .clean)
        coordinator.handle(denyEvent("disk4s1"))
        waitForPhase(coordinator, bsd: "disk4s1") { $0 == .awaitingRemount(.failOpen) }
        XCTAssertEqual(scanRequests.value.count, 0, "no scan without a private mount")
        let deadline = Date().addingTimeInterval(5)
        while remounter.remountedBSDNames.isEmpty, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(remounter.remountedBSDNames, ["disk4s1"])
    }

    // MARK: - Unplug and unknown-device tolerance

    func testDiskGoneForgetsTheHold() throws {
        let coordinator = makeCoordinator(scanState: .infected)
        coordinator.handle(denyEvent("disk4s1"))
        waitForPhase(coordinator, bsd: "disk4s1") { $0 == .heldInfected }
        coordinator.diskGone(bsdName: "disk4s1")
        coordinator.drain()
        XCTAssertNil(coordinator.phase(forBSDName: "disk4s1"))
    }

    func testUnknownDeviceStillRunsTheFlowWithoutClearance() throws {
        let coordinator = makeCoordinator(scanState: .clean, device: nil)
        coordinator.handle(denyEvent("disk9s1"))
        waitForPhase(coordinator, bsd: "disk9s1") { $0 == .awaitingRemount(.cleanScan) }
        XCTAssertEqual(clearedLog.value, [], "no identity, nothing to clear (extension fails open)")
        XCTAssertTrue(try eventKinds().contains("volume.held"),
                      "the record still says the drive was held")
    }
}
