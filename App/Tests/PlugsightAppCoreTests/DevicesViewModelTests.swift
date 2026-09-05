import XCTest
@testable import PlugsightAppCore
import PlugsightCore

@MainActor
final class DevicesViewModelTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    /// Pinned "now" on the canned event day so Today/Yesterday are stable.
    private var refNow: Date { Canned.timelineReferenceNow }

    func testPresentSortedByAttentionThenActivity() async {
        let vm = DevicesViewModel(api: FakeAPIClient())
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded, got \(vm.state)") }
        XCTAssertFalse(l.isEmpty)
        XCTAssertTrue(l.present.allSatisfy { $0.present })
        XCTAssertTrue(l.historical.allSatisfy { !$0.present })
        // Attention first: the yellow charger leads the green devices; the two
        // greens then sort by lastSeen desc (SanDisk 09:14 before Logitech 09:00).
        XCTAssertEqual(l.present.map(\.deviceId), ["dev_charger", "dev_sandisk", "dev_logi"])
    }

    // Quiet-chip rule: all-clear device shows NO chip; trust "none" → "Default".
    func testAllClearRowHasNoChipAndDefaultTrust() {
        let logi = Canned.devicesNormal.devices.first { $0.deviceId == "dev_logi" }!
        let row = DevicesViewModel.row(from: logi)  // score 4 = low
        XCTAssertNil(row.behaviorChipWord)
        let sandisk = Canned.devicesNormal.devices.first { $0.deviceId == "dev_sandisk" }!
        XCTAssertEqual(DevicesViewModel.row(from: sandisk).trustLabel, "Default")
    }

    // A high-score device shows the tier word (not the number) as a quiet chip.
    func testElevatedRowShowsTierWordNotNumber() {
        let charger = Canned.devicesNormal.devices.first { $0.deviceId == "dev_charger" }!
        let row = DevicesViewModel.row(from: charger)  // score 78 = high
        XCTAssertEqual(row.behaviorChipWord, "high")
        XCTAssertFalse(row.behaviorChipWord!.contains("78"))
    }

    // The Last scan cell: live scanning wins over the recorded last scan.
    func testScanningRowShowsScanningCell() {
        let sandisk = Canned.devicesNormal.devices.first { $0.deviceId == "dev_sandisk" }!
        let row = DevicesViewModel.row(from: sandisk, now: refNow, timeZone: utc)
        XCTAssertTrue(row.scanning)
        XCTAssertEqual(row.lastScanText, "Scanning…")
    }

    // A clean last scan renders its LOCAL finish time, never the ISO string.
    func testCleanLastScanCellShowsLocalTime() {
        var d = Canned.devicesNormal.devices.first { $0.deviceId == "dev_sandisk" }!
        d.scanning = false
        let row = DevicesViewModel.row(from: d, now: refNow, timeZone: utc)
        let time = TimeFormatting.timeOnly("2026-08-25T09:10:45Z", timeZone: utc)
        XCTAssertEqual(row.lastScanText, "Today \(time)")
        XCTAssertFalse(row.lastScanText.contains("Z"))
    }

    // A failed last scan leads with the plain state word, then the time.
    func testFailedLastScanCellShowsWordAndTime() {
        var d = Canned.devicesNormal.devices.first { $0.deviceId == "dev_sandisk" }!
        d.scanning = false
        d.lastScan = LastScanDTO(scanId: "scn_9", state: .failed,
                                 finishedAt: "2026-08-25T09:56:00Z")
        let row = DevicesViewModel.row(from: d, now: refNow, timeZone: utc)
        let time = TimeFormatting.timeOnly("2026-08-25T09:56:00Z", timeZone: utc)
        XCTAssertEqual(row.lastScanText, "Failed, Today \(time)")
    }

    // The nothing-states are honest: storage says "No scan", others "Not a drive".
    func testNoScanCellsSplitByStorageRole() {
        var storage = Canned.devicesNormal.devices.first { $0.deviceId == "dev_sandisk" }!
        storage.scanning = false
        storage.lastScan = nil
        XCTAssertEqual(DevicesViewModel.row(from: storage).lastScanText, "No scan")
        let keyboard = Canned.devicesNormal.devices.first { $0.deviceId == "dev_charger" }!
        XCTAssertEqual(DevicesViewModel.row(from: keyboard).lastScanText, "Not a drive")
    }

    // The Last check cell answers WHEN: "Now" while present; a local time when
    // absent. Never the whether-word "Connected" in a when-column.
    func testLastCheckCell() {
        let present = Canned.devicesNormal.devices.first { $0.deviceId == "dev_logi" }!
        XCTAssertEqual(DevicesViewModel.row(from: present).lastCheckText, "Now")
        let absent = Canned.devicesNormal.devices.first { $0.deviceId == "dev_webcam" }!
        let row = DevicesViewModel.row(from: absent, now: refNow, timeZone: utc)
        let time = TimeFormatting.timeOnly("2026-08-24T18:00:00Z", timeZone: utc)
        XCTAssertEqual(row.lastCheckText, "Yesterday \(time)")
        XCTAssertFalse(row.lastCheckText.contains("Z"))
    }

    // A missing safetyStatus (older daemon) reads as grey, never a crash or green.
    func testMissingSafetyStatusIsGrey() {
        let webcam = Canned.devicesNormal.devices.first { $0.deviceId == "dev_webcam" }!
        XCTAssertEqual(DevicesViewModel.row(from: webcam).safetyStatus, "grey")
    }

    // The behavior chip speaks plain language: the mid tier reads
    // "unusual typing", never the internal token "elevated". Low shows no chip.
    func testBehaviorChipWordIsPlainLanguage() {
        XCTAssertNil(BehaviorVocabulary.rowChipWord(for: 10))
        XCTAssertEqual(BehaviorVocabulary.rowChipWord(for: 55), "unusual typing")
        XCTAssertEqual(BehaviorVocabulary.rowChipWord(for: 80), "high")
    }

    // Repeated role words dedupe in the row ("network adapter" reads once).
    func testRowRolesDeduplicate() {
        var d = Canned.devicesNormal.devices.first { $0.deviceId == "dev_webcam" }!
        d.interfaceClasses = ["network", "cdc"]
        XCTAssertEqual(DevicesViewModel.row(from: d).roles, ["network adapter"])
    }

    // MARK: - Fleet verdict band

    private func row(_ id: String, status: String, reason: String? = nil,
                     name: String? = nil, lastSeen: String = "2026-08-25T09:00:00Z") -> DeviceRow {
        DeviceRow(deviceId: id, name: name ?? id, roles: ["storage"], trustLabel: "Default",
                  trustTier: TrustTier.none, behaviorChipWord: nil, present: true,
                  scanning: false, activeAlerts: 0, safetyStatus: status,
                  leadReason: reason, lastScanText: "No scan", lastCheckText: "Now",
                  lastSeen: lastSeen)
    }

    func testVerdictAllGreen() {
        let v = DevicesViewModel.fleetVerdict(present: [
            row("a", status: "green"), row("b", status: "green")])
        XCTAssertEqual(v?.status, "green")
        XCTAssertEqual(v?.headline, "Everything connected looks safe")
        XCTAssertNil(v?.detail)
    }

    func testVerdictSingleYellowNamesDeviceAndReason() {
        let v = DevicesViewModel.fleetVerdict(present: [
            row("a", status: "green"),
            row("b", status: "yellow", reason: "The last scan did not finish.",
                name: "SanDisk Ultra")])
        XCTAssertEqual(v?.status, "yellow")
        XCTAssertEqual(v?.headline, "1 device needs attention")
        XCTAssertEqual(v?.detail,
                       "SanDisk Ultra. The last scan did not finish. Everything else connected looks safe.")
    }

    func testVerdictRedLeadsEvenWithYellows() {
        let v = DevicesViewModel.fleetVerdict(present: [
            row("a", status: "red", name: "Bad Drive"),
            row("b", status: "yellow"), row("c", status: "green")])
        XCTAssertEqual(v?.status, "red")
        XCTAssertEqual(v?.headline, "1 device is unsafe")
        XCTAssertEqual(v?.detail, "Bad Drive. 1 more device needs attention.")
    }

    func testVerdictGreyOnlyFleetIsNotCheckedYet() {
        let v = DevicesViewModel.fleetVerdict(present: [
            row("a", status: "grey"), row("b", status: "grey")])
        XCTAssertEqual(v?.status, "grey")
        XCTAssertEqual(v?.headline, "Not checked yet")
    }

    func testVerdictGreenWithGreysStaysHonest() {
        let v = DevicesViewModel.fleetVerdict(present: [
            row("a", status: "green"), row("b", status: "grey")])
        XCTAssertEqual(v?.status, "green")
        XCTAssertEqual(v?.detail, "1 device has not been checked yet.")
    }

    func testVerdictNilWhenNothingConnected() {
        XCTAssertNil(DevicesViewModel.fleetVerdict(present: []))
    }

    // MARK: - Search

    func testSearchFiltersByNameAndRole() async {
        let vm = DevicesViewModel(api: FakeAPIClient())
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        let byName = l.filtered(query: "sandisk")
        XCTAssertEqual(byName.present.map(\.deviceId), ["dev_sandisk"])
        let byRole = l.filtered(query: "keyboard")
        XCTAssertTrue(byRole.present.map(\.deviceId).contains("dev_charger"))
        XCTAssertFalse(byRole.present.map(\.deviceId).contains("dev_sandisk"))
        // The band keeps judging the whole fleet, not the filtered view.
        XCTAssertEqual(byName.verdict, l.verdict)
        // Blank queries change nothing.
        XCTAssertEqual(l.filtered(query: "  ").present, l.present)
    }

    func testEmptyStateSentence() async {
        let fake = FakeAPIClient(devices: .success(Canned.devicesEmpty))
        let vm = DevicesViewModel(api: fake)
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.isEmpty)
        XCTAssertEqual(l.emptySentence, "Nothing has been plugged in since installation.")
        XCTAssertFalse(l.showsSearch)
        XCTAssertNil(l.verdict)
    }

    func testSearchAppearsPastTenDevices() async {
        let fake = FakeAPIClient(devices: .success(Canned.devicesAtScale))
        let vm = DevicesViewModel(api: fake)
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.showsSearch)
        XCTAssertEqual(l.present.count, 20)
        // Attention order holds at scale: the one red device leads.
        XCTAssertEqual(l.present.first?.safetyStatus, "red")
    }

    func testStoreError() async {
        let fake = FakeAPIClient(devices: .failure(APIError(kind: .storeUnreadable, message: "Can't read the device record")))
        let vm = DevicesViewModel(api: fake)
        await vm.load()
        guard case .storeError(let msg) = vm.state else { return XCTFail("expected storeError") }
        XCTAssertEqual(msg, "Can't read the device record")
    }

    // Junk descriptor never renders VID/PID alone (2b).
    func testFallbackNameNeverHex() {
        let junk = DeviceSummaryDTO(deviceId: "dev_x", name: "", present: true,
            firstSeen: "t", lastSeen: "t", vidPid: "1a2b:0001", serial: nil,
            interfaceClasses: ["hid_keyboard"], trust: "none", score: nil, activeAlerts: 0)
        let row = DevicesViewModel.row(from: junk)
        XCTAssertEqual(row.name, "Unnamed keyboard")
        XCTAssertFalse(row.name.contains("1a2b"))
    }
}
