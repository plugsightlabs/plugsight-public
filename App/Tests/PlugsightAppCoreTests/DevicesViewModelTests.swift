import XCTest
@testable import PlugsightAppCore

@MainActor
final class DevicesViewModelTests: XCTestCase {

    func testNormalPresentFirstSortedByActivity() async {
        let vm = DevicesViewModel(api: FakeAPIClient())
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded, got \(vm.state)") }
        XCTAssertFalse(l.isEmpty)
        XCTAssertTrue(l.present.allSatisfy { $0.present })
        XCTAssertTrue(l.historical.allSatisfy { !$0.present })
        // Present sorted by lastSeen desc → SanDisk (09:14) leads Logitech (09:00).
        XCTAssertEqual(l.present.first?.deviceId, "dev_sandisk")
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

    func testScanningRowFlag() {
        let sandisk = Canned.devicesNormal.devices.first { $0.deviceId == "dev_sandisk" }!
        XCTAssertTrue(DevicesViewModel.row(from: sandisk).scanning)
    }

    func testEmptyStateSentence() async {
        let fake = FakeAPIClient(devices: .success(Canned.devicesEmpty))
        let vm = DevicesViewModel(api: fake)
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.isEmpty)
        XCTAssertEqual(l.emptySentence, "Nothing has been plugged in since installation.")
        XCTAssertFalse(l.showsSearch)
    }

    func testSearchAppearsPastTenDevices() async {
        let fake = FakeAPIClient(devices: .success(Canned.devicesAtScale))
        let vm = DevicesViewModel(api: fake)
        await vm.load()
        guard case .loaded(let l) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertTrue(l.showsSearch)
        XCTAssertEqual(l.present.count, 20)
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
