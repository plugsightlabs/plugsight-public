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

    // MARK: - Verdict (leads the pane)

    func testVerdictMapsStatusAndActions() {
        let v = DeviceInspectorViewModel.verdict(from: Canned.deviceStorageInfected.safetyStatus)
        XCTAssertEqual(v.status, "red")
        XCTAssertEqual(v.reasons.count, 1)
        XCTAssertEqual(v.reasons[0].action, .reviewQuarantine)
        XCTAssertEqual(v.reasons[0].sentence, "The last scan found malware. 1 file was quarantined.")
    }

    // A daemon without the verdict model reads as grey — never invented safety.
    func testMissingSafetyStatusIsGreyVerdict() {
        let v = DeviceInspectorViewModel.verdict(from: nil)
        XCTAssertEqual(v.status, "grey")
        XCTAssertTrue(v.reasons.isEmpty)
    }

    // Regression (judge finding): a device with a terminal scan on record is
    // NOT "never checked". With no wire verdict, the newest terminal scan
    // derives the colour: clean reads green, malware reads red.
    func testMissingSafetyStatusWithScanHistoryDerivesFromLastTerminalScan() {
        func row(_ id: String, _ state: ScanDTO.State, finishedAt: String?) -> ScanRecordVM {
            ScanRecordVM(scanId: id, state: state, progress: nil, reason: nil,
                         startedAt: "2026-08-25T09:00:00Z", finishedAt: finishedAt,
                         verdicts: [], quarantine: [])
        }
        let clean = DeviceInspectorViewModel.verdict(
            from: nil, scans: [row("s1", .clean, finishedAt: "2026-08-25T09:10:00Z")])
        XCTAssertEqual(clean.status, "green",
                       "a clean last scan must not render as 'Not checked'")
        let infected = DeviceInspectorViewModel.verdict(
            from: nil, scans: [row("s2", .infected, finishedAt: "2026-08-25T09:10:00Z"),
                               row("s1", .clean, finishedAt: "2026-08-24T09:10:00Z")])
        XCTAssertEqual(infected.status, "red")
        // Failed-only history stays grey (no terminal verdict to derive from).
        let failedOnly = DeviceInspectorViewModel.verdict(
            from: nil, scans: [row("s3", .failed, finishedAt: nil)])
        XCTAssertEqual(failedOnly.status, "grey")
    }

    // An absent device with a clean scan history keeps its derived verdict AND
    // its absent note (the note carries absence; the verdict carries the check).
    func testAbsentDeviceWithCleanScanKeepsVerdictAndAbsentNote() async {
        var detail = Canned.deviceStorageAbsent
        detail.isStorage = true
        detail.interfaces = [.init(seq: 0, usbClass: 8, subclass: 6, proto: 80, role: "storage")]
        let fake = FakeAPIClient(device: .success(detail),
                                 scans: .success(Canned.scansClean))
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_webcam")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertEqual(l.verdict.status, "green")
        XCTAssertNotNil(l.header.absentNote)
    }

    // The Behavior card gate: only devices with a keyboard face carry it.
    func testInputFaceDerivedFromInterfaces() async {
        let keyboard = DeviceInspectorViewModel(api: FakeAPIClient(), deviceId: "dev_charger")
        await keyboard.load()
        guard case .loaded(let kb) = keyboard.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(kb.header.hasInputFace)

        let camera = DeviceInspectorViewModel(
            api: FakeAPIClient(device: .success(Canned.deviceStorageAbsent)), deviceId: "dev_webcam")
        await camera.load()
        guard case .loaded(let cam) = camera.state else { return XCTFail("expected loaded") }
        XCTAssertFalse(cam.header.hasInputFace,
                       "a camera has no typing face; the Behavior card must not render for it")
    }

    // Repeated role words dedupe ("network adapter, network adapter" reads once).
    func testHeaderRolesDeduplicate() async {
        var detail = Canned.deviceKeyboard
        detail.interfaces = [
            .init(seq: 0, usbClass: 2, subclass: 6, proto: 0, role: "network"),
            .init(seq: 1, usbClass: 2, subclass: 6, proto: 0, role: "cdc"),
        ]
        let vm = DeviceInspectorViewModel(api: FakeAPIClient(device: .success(detail)),
                                          deviceId: "dev_charger")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertEqual(l.header.rolesText, "network adapter")
    }

    // Unknown wire actions degrade to advice-free text, never a dead button.
    func testUnknownActionDegradesGracefully() {
        let action = SafetyAction(wire: "holdDrive")
        XCTAssertEqual(action, .other("holdDrive"))
        XCTAssertNil(action.buttonLabel)
        XCTAssertNil(action.adviceText)
    }

    // The infected scan is enriched with its quarantine records (scan.get) so
    // the reviewQuarantine reason lists them with a working Restore.
    func testInfectedScanCarriesQuarantineRows() async {
        let fake = FakeAPIClient(device: .success(Canned.deviceStorageInfected),
                                 scans: .success(Canned.scansInfectedHistory))
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_sandisk")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertEqual(l.quarantineRows.map(\.quarantineId), ["qtn_1"])
        XCTAssertEqual(l.verdict.status, "red")
    }

    // The inspector loads this device's ACTIVE alerts for the reviewAlerts list.
    func testLoadsActiveAlertsForDevice() async {
        let vm = DeviceInspectorViewModel(api: FakeAPIClient(), deviceId: "dev_charger")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertEqual(l.alerts.map(\.alertId), ["alt_1"])
    }

    // MARK: - Verdict / scan / alert actions (async, inline error, refresh)

    func testScanNowCallsAPIAndRefreshes() async {
        let fake = FakeAPIClient()
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_sandisk")
        await vm.load()
        await vm.scanNow()
        XCTAssertEqual(fake.lastScanStorageDeviceId, "dev_sandisk")
        XCTAssertNil(vm.actionError)
    }

    func testScanNowFailureSurfacesInline() async {
        let fake = FakeAPIClient()
        fake.scanStorageResult = .failure(APIError(kind: .scannerUnavailable,
                                                   message: "The scanner is not installed."))
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_sandisk")
        await vm.load()
        await vm.scanNow()
        XCTAssertEqual(vm.actionError, "The scanner is not installed.")
        // The pane is preserved: still loaded, never wiped by a failed action.
        guard case .loaded = vm.state else { return XCTFail("expected loaded") }
        vm.dismissActionError()
        XCTAssertNil(vm.actionError)
    }

    func testCancelRestoreAcknowledgeCallThrough() async {
        let fake = FakeAPIClient()
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_sandisk")
        await vm.load()
        await vm.cancelScan(scanId: "scn_2")
        XCTAssertEqual(fake.lastCancelScanId, "scn_2")
        await vm.restoreQuarantine(quarantineId: "qtn_1")
        XCTAssertEqual(fake.lastRestore?.quarantineId, "qtn_1")
        XCTAssertEqual(fake.lastRestore?.confirm, true, "restore is always explicit-confirm")
        await vm.acknowledgeAlert(alertId: "alt_1")
        XCTAssertEqual(fake.lastAckAlertId, "alt_1")
        XCTAssertNil(vm.actionError)
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

    // Timezone honesty: the absent note shows a formatted LOCAL time, never the
    // raw ISO string the wire carries.
    func testAbsentNoteFormatsLastSeenLocally() async {
        let fake = FakeAPIClient(device: .success(Canned.deviceStorageAbsent))
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_webcam")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        let note = try? XCTUnwrap(l.header.absentNote)
        XCTAssertEqual(note?.contains("2026-08-24T18:00:00Z"), false,
                       "the note must not interpolate the raw ISO timestamp")
        XCTAssertEqual(note, "Not connected, last seen \(TimeFormatting.dateTime("2026-08-24T18:00:00Z")).")
        // The header also exposes the display string for other renderers.
        XCTAssertEqual(l.header.lastSeenDisplay, TimeFormatting.dateTime("2026-08-24T18:00:00Z"))
        XCTAssertFalse(l.header.lastSeenDisplay.contains("Z"))
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

    // Scan rows carry their facts: times and reason survive into the VM row,
    // and the display strings are local wall-clock text, not sliced ISO.
    func testScanRecordsCarryTimesAndReason() async {
        let fake = FakeAPIClient()
        fake.scansResult = .success(ScanListDTO(scans: [
            ScanSummaryDTO(scanId: "scn_f", deviceId: "dev_sandisk", state: .failed,
                engine: "clamdscan", startedAt: "2026-08-25T09:17:00Z",
                finishedAt: "2026-08-25T09:17:30Z", filesScanned: 0,
                reason: "The scan did not finish."),
        ]))
        let vm = DeviceInspectorViewModel(api: fake, deviceId: "dev_sandisk")
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        let row = l.scans[0]
        XCTAssertEqual(row.startedAt, "2026-08-25T09:17:00Z")
        XCTAssertEqual(row.finishedAt, "2026-08-25T09:17:30Z")
        XCTAssertEqual(row.reason, "The scan did not finish.")
        // Display helpers: parsed + formatted, never the raw ISO string.
        XCTAssertNotEqual(row.startedAtDisplay, row.startedAt)
        XCTAssertFalse(row.startedAtDisplay.contains("Z"))
        XCTAssertTrue(row.startedAtDisplay.contains("2026"))
        XCTAssertEqual(row.finishedAtDisplay?.contains("Z"), false)
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
