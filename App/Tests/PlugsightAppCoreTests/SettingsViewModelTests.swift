import XCTest
@testable import PlugsightAppCore

@MainActor
final class SettingsViewModelTests: XCTestCase {

    func testPermissionRowsReflectStatus() {
        let loaded = SettingsViewModel.build(status: Canned.statusDegraded, policy: Canned.policyDefault)
        let im = loaded.permissions.first { $0.key == "input_monitoring" }
        XCTAssertNotNil(im)
        guard case .missing = im!.state else { return XCTFail("Input Monitoring should be missing") }
        XCTAssertFalse(im!.capability.isEmpty, "each row states its capability in one sentence")
    }

    // 8b: Hold-new-drives toggle DISABLED with an inline reason naming the exact
    // missing prerequisite, never hover-only.
    func testHoldNewDrivesDisabledWithInlineReasonWhenExtensionInactive() {
        let loaded = SettingsViewModel.build(status: Canned.statusScannerMissing, policy: Canned.policyDefault)
        let toggle = loaded.protection.holdNewDrives
        XCTAssertFalse(toggle.enabled)
        XCTAssertNotNil(toggle.disabledReason)
        XCTAssertTrue(toggle.disabledReason!.contains("system extension"))
    }

    func testHoldNewDrivesEnabledWhenPrereqsMet() {
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault)
        XCTAssertTrue(loaded.protection.holdNewDrives.enabled)
        XCTAssertNil(loaded.protection.holdNewDrives.disabledReason)
    }

    // Definitions age "unknown" is its own muted state (nil age).
    func testDefinitionsAgeUnknownWhenNil() {
        let loaded = SettingsViewModel.build(status: Canned.statusScannerMissing, policy: Canned.policyDefault)
        XCTAssertEqual(loaded.scanner.definitionsAgeText, "unknown")
        XCTAssertTrue(loaded.scanner.showsGuidedInstall)  // engine absent
    }

    func testDefinitionsAgeRendersDays() {
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault)
        XCTAssertEqual(loaded.scanner.definitionsAgeText, "2 days old")
        XCTAssertFalse(loaded.scanner.showsGuidedInstall)
    }

    // Threshold picker options describe themselves (no jargon, no ladder ranking).
    func testThresholdOptionsSelfDescribe() {
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault)
        XCTAssertEqual(loaded.protection.thresholdOptions.map(\.label),
                       ["Only critical", "Warnings and critical", "Everything"])
        XCTAssertEqual(loaded.protection.notificationThresholdLabel, "Warnings and critical")
    }

    // No jargon: the toggle is "Hold new drives until scanned", never "mount-hold".
    func testNoJargonInDisabledReason() {
        let loaded = SettingsViewModel.build(status: Canned.statusScannerMissing, policy: Canned.policyDefault)
        let reason = loaded.protection.holdNewDrives.disabledReason ?? ""
        XCTAssertFalse(reason.lowercased().contains("mount-hold"))
        XCTAssertFalse(reason.lowercased().contains("iokit"))
        XCTAssertFalse(reason.lowercased().contains("clamd"))
    }

    func testLoadReachesLoaded() async {
        let vm = SettingsViewModel(api: FakeAPIClient())
        await vm.load()
        guard case .loaded = vm.state else { return XCTFail("expected loaded, got \(vm.state)") }
    }
}
