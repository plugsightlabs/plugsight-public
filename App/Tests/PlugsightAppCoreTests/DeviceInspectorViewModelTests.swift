import XCTest
@testable import PlugsightAppCore
import PlugsightCore

@MainActor
final class DeviceInspectorViewModelTests: XCTestCase {

    // Null-not-zero: a NUMBER shows in exactly the honest case.
    func testBehaviorCardShowsNumberOnlyWhenObserved() {
        XCTAssertTrue(DeviceInspectorViewModel.behaviorCard(from: Canned.scoreElevated).showsNumber)
        XCTAssertFalse(DeviceInspectorViewModel.behaviorCard(from: Canned.scoreSensorOff).showsNumber)
        XCTAssertFalse(DeviceInspectorViewModel.behaviorCard(from: Canned.scoreNoData).showsNumber)
    }

    func testSensorOffSaysSensorOffNotNoTyping() {
        let card = DeviceInspectorViewModel.behaviorCard(from: Canned.scoreSensorOff)
        guard case .sensorOff(let msg) = card else { return XCTFail("expected sensorOff") }
        XCTAssertTrue(msg.contains("Input Monitoring"))
        XCTAssertFalse(msg.lowercased().contains("no typing observed"))
    }

    func testSensorOnNoDataSaysNoTyping() {
        let card = DeviceInspectorViewModel.behaviorCard(from: Canned.scoreNoData)
        guard case .noData(let msg) = card else { return XCTFail("expected noData") }
        XCTAssertEqual(msg, "No typing observed from this device")
    }

    func testScoreCardCarriesTierWordAndCaveat() {
        let card = DeviceInspectorViewModel.behaviorCard(from: Canned.scoreElevated)
        guard case .score(let value, let tierWord, _, let caveat) = card else { return XCTFail() }
        XCTAssertEqual(value, 78)
        XCTAssertEqual(tierWord, "high")
        XCTAssertEqual(caveat, BehaviorVocabulary.caveat)
    }

    func testTrustSegmentsShowDefaultNotNone() async {
        let vm = DeviceInspectorViewModel(api: FakeAPIClient(), deviceId: "dev_charger")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded, got \(vm.state)") }
        XCTAssertEqual(l.trust.segments.map(\.tier), [.trusted, .none, .muted, .flagged])
        let defaultSeg = l.trust.segments.first { $0.tier == .none }!
        XCTAssertEqual(defaultSeg.label, "Default")
    }

    func testStorageHeaderShowsEject() async {
        let fake = FakeAPIClient()
        var d = Canned.deviceKeyboard
        d = DeviceDetailDTO(deviceId: d.deviceId, name: "SanDisk Ultra", present: true,
            firstSeen: d.firstSeen, lastSeen: d.lastSeen, vidPid: "0781:5581", serial: "AA0102",
            trust: "none", interfaces: [.init(seq: 0, usbClass: 8, subclass: 6, proto: 80, role: "storage")],
            topology: nil, trustHistory: [], isStorage: true)
        fake.deviceResult = .success(d)
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_sandisk")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.header.showsEject)
    }

    // Absent device: note present, trust control still active (6c).
    func testAbsentDeviceNoteAndTrustStillActive() async {
        let fake = FakeAPIClient(device: .success(Canned.deviceStorageAbsent))
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_webcam")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertNotNil(l.header.absentNote)
        XCTAssertEqual(l.trust.segments.count, 4)  // control still rendered
    }

    // Scan record actions: Cancel on running, Retry on failed, never on clean.
    func testScanActionsAvailability() async {
        let fake = FakeAPIClient()
        // scans.list returns SUMMARIES; the record actions are driven by state.
        fake.scansResult = .success(ScanListDTO(scans: [
            ScanSummaryDTO(scanId: "scn_r", deviceId: "dev_sandisk", state: .running,
                engine: "clamdscan", startedAt: "2026-08-25T09:15:00Z", finishedAt: nil, filesScanned: 3),
            ScanSummaryDTO(scanId: "scn_f", deviceId: "dev_sandisk", state: .failed,
                engine: "clamdscan", startedAt: "2026-08-25T09:17:00Z", finishedAt: "2026-08-25T09:17:30Z", filesScanned: 0),
            ScanSummaryDTO(scanId: "scn_c", deviceId: "dev_sandisk", state: .clean,
                engine: "clamdscan", startedAt: "2026-08-25T09:10:00Z", finishedAt: "2026-08-25T09:10:40Z", filesScanned: 128),
        ]))
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_sandisk")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        let running = l.scans.first { $0.state == .running }!
        let failed = l.scans.first { $0.state == .failed }!
        let clean = l.scans.first { $0.state == .clean }!
        XCTAssertTrue(running.showsCancel)
        XCTAssertTrue(failed.showsRetry)
        XCTAssertFalse(clean.showsCancel)
        XCTAssertFalse(clean.showsRetry)
    }

    // First-ever trust action raises the forgeability note; the write applies.
    func testFirstTrustShowsForgeabilityNoteAndAppliesImmediately() async {
        let fake = FakeAPIClient()
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_charger", hasEverSetTrust: false)
        await vm.load()
        await vm.setTrust(.trusted)
        XCTAssertEqual(fake.lastTrust?.tier, "trusted")
        XCTAssertNotNil(vm.undoToast)
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.trust.showForgeabilityNote)
    }

    // Trust write failure preserves value and surfaces an inline error.
    func testTrustWriteFailurePreservesAndExplains() async {
        let fake = FakeAPIClient()
        fake.setTrustResult = .failure(APIError(kind: .transport, message: "Couldn’t save the trust setting."))
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_charger")
        await vm.load()
        await vm.setTrust(.muted)
        XCTAssertEqual(vm.trustWriteError, "Couldn’t save the trust setting.")
    }

    // Undo writes the previous tier back and dismisses the toast.
    func testUndoTrustRestoresPreviousTierAndClearsToast() async {
        let fake = FakeAPIClient()
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_charger")
        await vm.load()
        await vm.setTrust(.flagged)
        XCTAssertEqual(fake.lastTrust?.tier, "flagged")
        XCTAssertNotNil(vm.undoToast)
        let previous = vm.undoToast!.previousTier
        await vm.undoTrust()
        XCTAssertEqual(fake.lastTrust?.tier, previous.rawValue, "undo re-applies the previous tier")
        XCTAssertNil(vm.undoToast, "undo dismisses the toast")
    }

    // Dismiss controls clear the transient toast/error without a write.
    func testDismissClearsToastAndError() async {
        let fake = FakeAPIClient()
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_charger")
        await vm.load()
        await vm.setTrust(.trusted)
        XCTAssertNotNil(vm.undoToast)
        vm.dismissUndo()
        XCTAssertNil(vm.undoToast)
        fake.setTrustResult = .failure(APIError(kind: .transport, message: "nope"))
        await vm.setTrust(.muted)
        XCTAssertNotNil(vm.trustWriteError)
        vm.dismissTrustWriteError()
        XCTAssertNil(vm.trustWriteError)
    }
}
