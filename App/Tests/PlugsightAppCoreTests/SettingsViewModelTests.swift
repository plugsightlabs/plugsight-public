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

    // WP2: the vestigial Full Disk Access row is removed entirely (FDA is not used
    // at runtime; scanning works on /Volumes without it).
    func testFullDiskAccessRowRemoved() {
        let loaded = SettingsViewModel.build(status: Canned.statusScannerMissing, policy: Canned.policyDefault)
        XCTAssertEqual(loaded.permissions.map(\.key), ["input_monitoring", "system_extension"])
        XCTAssertNil(loaded.permissions.first { $0.key == "full_disk_access" },
                     "the Full Disk Access row must be gone")
    }

    // WP2: purpose-led titles with the OS permission name as a secondary line, and
    // the Input Monitoring capability reframed honestly (timing only, keys never read).
    func testPermissionRowsArePurposeLedWithOSNameSecondary() {
        let loaded = SettingsViewModel.build(status: Canned.statusDegraded, policy: Canned.policyDefault)
        let byKey = Dictionary(uniqueKeysWithValues: loaded.permissions.map { ($0.key, $0) })
        XCTAssertEqual(byKey["input_monitoring"]?.title, "Typing-rhythm check")
        XCTAssertEqual(byKey["input_monitoring"]?.osName, "Input Monitoring")
        XCTAssertEqual(byKey["system_extension"]?.title, "Deeper device monitoring")
        XCTAssertEqual(byKey["system_extension"]?.osName, "System Extension")
        let imCap = byKey["input_monitoring"]!.capability.lowercased()
        XCTAssertTrue(imCap.contains("timing"), "capability is timing-only")
        XCTAssertTrue(imCap.contains("never the keys themselves"), "capability says keys are not read")
        XCTAssertFalse(byKey["input_monitoring"]!.capability.contains("\u{2014}"))
    }

    // WP2: the "Scan drives when they mount" toggle reads the real policy (ON by
    // default post-WP1) and persists via setPolicy(scanOnMount:).
    func testScanOnMountReflectsPolicyAndPersists() async {
        let onLoaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault)
        XCTAssertTrue(onLoaded.scanner.scanOnMount, "scan-on-mount defaults ON (WP1)")

        let api = FakeAPIClient()
        let vm = SettingsViewModel(api: api)
        await vm.setScanOnMount(false)
        XCTAssertEqual(api.lastPolicy?.scanOnMount, false,
                       "the toggle writes the scanOnMount policy")
    }

    // WP2: the shared trust line is present and clean for the Settings surface.
    func testTrustLinePresentForSettings() {
        XCTAssertTrue(TrustCopy.stayOnMac.contains("stays on your Mac"))
        XCTAssertFalse(TrustCopy.stayOnMac.contains("\u{2014}"))
    }

    // 1e: a missing permission row carries the exact System Settings pane URL, so
    // the Grant / Open button opens the SAME pane the onboarding walk does (single
    // source: OnboardingStateMachine.degradedConsequence).
    func testMissingPermissionRowsCarryTheirSettingsDeepLink() {
        let loaded = SettingsViewModel.build(status: Canned.statusDegraded, policy: Canned.policyDefault)
        let byKey = Dictionary(uniqueKeysWithValues: loaded.permissions.map { ($0.key, $0) })
        XCTAssertEqual(byKey["input_monitoring"]?.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertEqual(byKey["system_extension"]?.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?Security")
        // The scanner is no longer a permission row at all (WP2): no System
        // Settings pane installs a scanner; its recovery is the guided install /
        // one-click install, so the old Full Disk Access row is gone entirely.
        XCTAssertNil(byKey["full_disk_access"], "the Full Disk Access row is removed")
    }

    // The extension row reflects its THREE real states distinctly (the app knows
    // which one it is), so "installed, waiting for your approval" no longer looks
    // identical to "not set up". Each not-granted state carries a guided hint.
    private func extRow(_ ext: StatusDTO.ExtensionState) -> PermissionRow {
        let status = StatusDTO(
            monitoring: .active, daemonVersion: "1.0.0",
            permissions: .init(inputMonitoring: true, esExtension: ext),
            scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2,
                           installState: .done, installDetail: nil),
            devicesPresent: 1, activeAlerts: 0, monitoringGaps: [])
        let loaded = SettingsViewModel.build(status: status, policy: Canned.policyDefault)
        return loaded.permissions.first { $0.key == "system_extension" }!
    }

    func testExtensionActiveIsGrantedWithNoHint() {
        let r = extRow(.active)
        guard case .granted = r.state else { return XCTFail("active → granted") }
        XCTAssertNil(r.state.actionLabel)
        XCTAssertNil(r.hint)
    }

    func testExtensionInactiveIsPendingWithApprovalHint() {
        let r = extRow(.inactive)
        guard case .pending(let action) = r.state else { return XCTFail("inactive → pending") }
        XCTAssertEqual(action, "Approve in System Settings")
        XCTAssertEqual(r.state.actionLabel, "Approve in System Settings")
        XCTAssertNotNil(r.hint)
        XCTAssertTrue(r.hint!.contains("Login Items"), "hint names where to switch it on")
        XCTAssertFalse(r.hint!.contains("\u{2014}"), "no em dashes in shipped prose")
    }

    func testExtensionNotInstalledIsMissingWithSetupHint() {
        let r = extRow(.notInstalled)
        guard case .missing(let action) = r.state else { return XCTFail("notInstalled → missing") }
        XCTAssertEqual(action, "Turn on")
        XCTAssertNotNil(r.hint)
        XCTAssertFalse(r.hint!.contains("\u{2014}"))
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
