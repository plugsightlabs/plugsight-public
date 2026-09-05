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

    // A NOT-granted row carries numbered steps naming the exact pane, plus the
    // action button — a guided path, never a bare deep link.
    func testMissingInputMonitoringCarriesNumberedSteps() {
        let loaded = SettingsViewModel.build(status: Canned.statusDegraded, policy: Canned.policyDefault)
        let im = loaded.permissions.first { $0.key == "input_monitoring" }!
        XCTAssertEqual(im.state.actionLabel, "Open System Settings")
        XCTAssertEqual(im.steps.count, 3)
        XCTAssertTrue(im.steps[0].contains("Open System Settings"))
        XCTAssertTrue(im.steps[1].contains("Input Monitoring"), "step names the exact pane")
        XCTAssertTrue(im.steps[2].contains("Switch it on"))
        for step in im.steps { XCTAssertFalse(step.contains("\u{2014}")) }
    }

    // A GRANTED row shows no steps and no button — just the capability sentence.
    func testGrantedRowHasNoStepsOrButton() {
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault)
        let im = loaded.permissions.first { $0.key == "input_monitoring" }!
        guard case .granted = im.state else { return XCTFail("expected granted") }
        XCTAssertNil(im.state.actionLabel)
        XCTAssertTrue(im.steps.isEmpty)
        XCTAssertNil(im.note)
    }

    // Input Monitoring granted while the sensor waits for a daemon restart: the
    // row says so in plain words (text only, no fake button).
    func testGrantedWithRestartRequiredSensorCarriesPlainNote() {
        var status = Canned.statusActive
        status.permissions.inputMonitoringSensor = "restart_required"
        let loaded = SettingsViewModel.build(status: status, policy: Canned.policyDefault)
        let im = loaded.permissions.first { $0.key == "input_monitoring" }!
        guard case .granted = im.state else { return XCTFail("expected granted") }
        XCTAssertEqual(im.note, "Granted. The typing check starts after the next daemon restart.")
        XCTAssertNil(im.state.actionLabel, "no fake button on the note")
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
        XCTAssertNil(byKey["full_disk_access"], "the Full Disk Access row is removed")
    }

    // MARK: - The system-extension row's three real states (bundled build)

    private func extRow(_ ext: StatusDTO.ExtensionState,
                        extensionBundled: Bool = true,
                        activationError: String? = nil) -> PermissionRow {
        let status = StatusDTO(
            monitoring: .active, daemonVersion: "1.0.0",
            permissions: .init(inputMonitoring: true, inputMonitoringSensor: "active",
                               esExtension: ext),
            scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2,
                           installState: .done, installDetail: nil),
            devicesPresent: 1, activeAlerts: 0, monitoringGaps: [])
        let loaded = SettingsViewModel.build(status: status, policy: Canned.policyDefault,
                                             extensionBundled: extensionBundled,
                                             activationError: activationError)
        return loaded.permissions.first { $0.key == "system_extension" }!
    }

    func testExtensionActiveIsGrantedWithNoSteps() {
        let r = extRow(.active)
        guard case .granted = r.state else { return XCTFail("active → granted") }
        XCTAssertNil(r.state.actionLabel)
        XCTAssertTrue(r.steps.isEmpty)
        XCTAssertNil(r.errorLine)
    }

    func testExtensionInactiveIsPendingWithApprovalSteps() {
        let r = extRow(.inactive)
        guard case .pending(let action) = r.state else { return XCTFail("inactive → pending") }
        XCTAssertEqual(action, "Approve in System Settings")
        XCTAssertEqual(r.steps.count, 3)
        XCTAssertTrue(r.steps.contains { $0.contains("Login Items") },
                      "a step names where to switch it on")
        for step in r.steps { XCTAssertFalse(step.contains("\u{2014}"), "no em dashes in shipped prose") }
    }

    func testExtensionNotInstalledIsMissingWithSetupSteps() {
        let r = extRow(.notInstalled)
        guard case .missing(let action) = r.state else { return XCTFail("notInstalled → missing") }
        XCTAssertEqual(action, "Turn on")
        XCTAssertFalse(r.steps.isEmpty)
        for step in r.steps { XCTAssertFalse(step.contains("\u{2014}")) }
    }

    // Honesty: a build without the bundled extension shows plain text and NO
    // button, whatever the daemon reports (the same guard onboarding uses).
    func testUnbundledExtensionRowIsUnavailableWithNoButton() {
        let r = extRow(.inactive, extensionBundled: false)
        XCTAssertEqual(r.state, .unavailable)
        XCTAssertNil(r.state.actionLabel, "no button for an uninstallable capability")
        XCTAssertTrue(r.steps.isEmpty)
        XCTAssertEqual(r.capability,
                       "Not available yet. Waiting on Apple approval of the monitoring extension.")
        XCTAssertFalse(r.capability.contains("\u{2014}"))
    }

    // A failed activation surfaces its error inline on the row, never swallowed.
    func testActivationErrorSurfacesInlineOnBundledInactiveRow() {
        let r = extRow(.inactive, activationError: "Activation was not approved.")
        XCTAssertEqual(r.errorLine, "Activation was not approved.")
        // But a granted row never shows a stale error.
        let granted = extRow(.active, activationError: "Old failure.")
        XCTAssertNil(granted.errorLine)
    }

    // MARK: - Scanner (plain words, no raw engine/day-count table)

    func testScannerSpeaksPlainWordsWhenInstalled() {
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault)
        XCTAssertTrue(loaded.scanner.engineFound)
        XCTAssertEqual(loaded.scanner.statusLine, "Malware scanner: ClamAV installed.")
        XCTAssertEqual(loaded.scanner.definitionsLine, "Virus definitions updated 2 days ago.")
        XCTAssertFalse(loaded.scanner.definitionsStale)
        XCTAssertFalse(loaded.scanner.showsGuidedInstall)
        // No internal engine token ever reaches a sentence the user reads.
        XCTAssertFalse(loaded.scanner.statusLine.contains("clamdscan"))
        XCTAssertFalse(loaded.scanner.definitionsLine.contains("clamdscan"))
    }

    func testDefinitionsUpdatedTodayAndOneDayAgoGrammar() {
        var status = Canned.statusActive
        status.scanner.definitionsAgeDays = 0
        var loaded = SettingsViewModel.build(status: status, policy: Canned.policyDefault)
        XCTAssertEqual(loaded.scanner.definitionsLine, "Virus definitions updated today.")
        status.scanner.definitionsAgeDays = 1
        loaded = SettingsViewModel.build(status: status, policy: Canned.policyDefault)
        XCTAssertEqual(loaded.scanner.definitionsLine, "Virus definitions updated 1 day ago.")
    }

    func testDefinitionsNotDownloadedYetWhenNil() {
        let loaded = SettingsViewModel.build(status: Canned.statusScannerMissing, policy: Canned.policyDefault)
        XCTAssertEqual(loaded.scanner.definitionsLine, "Definitions not downloaded yet.")
        XCTAssertFalse(loaded.scanner.definitionsStale)
        XCTAssertTrue(loaded.scanner.showsGuidedInstall)  // engine absent
    }

    func testStaleDefinitionsFlagAtSevenDays() {
        var status = Canned.statusActive
        status.scanner.definitionsAgeDays = 7
        let loaded = SettingsViewModel.build(status: status, policy: Canned.policyDefault)
        XCTAssertTrue(loaded.scanner.definitionsStale)
        XCTAssertEqual(loaded.scanner.definitionsLine, "Virus definitions updated 7 days ago.")
        status.scanner.definitionsAgeDays = 6
        XCTAssertFalse(SettingsViewModel.build(status: status, policy: Canned.policyDefault)
            .scanner.definitionsStale)
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

    func testLoadReachesLoaded() async {
        let vm = SettingsViewModel(api: FakeAPIClient(),
                                   extensionBundled: { true }, activationError: { nil })
        await vm.load()
        guard case .loaded = vm.state else { return XCTFail("expected loaded, got \(vm.state)") }
    }

    // load() feeds the injected extension facts into the built rows.
    func testLoadUsesInjectedExtensionFacts() async {
        let vm = SettingsViewModel(api: FakeAPIClient(status: .success(Canned.statusScannerMissing)),
                                   extensionBundled: { false }, activationError: { nil })
        await vm.load()
        guard case .loaded(let loaded) = vm.state else { return XCTFail("expected loaded") }
        let ext = loaded.permissions.first { $0.key == "system_extension" }!
        XCTAssertEqual(ext.state, .unavailable)
    }

    // MARK: - Notifications section (Wave 2, 04 notification model)

    // Nil wire keys mean the defaults: notifyUnsafe on, notifyNewDevice off.
    func testNotificationsSectionDefaultsWhenKeysAbsent() {
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault,
                                             notificationAuthorization: .authorized)
        XCTAssertTrue(loaded.notifications.notifyUnsafe, "nil notifyUnsafe means on")
        XCTAssertFalse(loaded.notifications.notifyNewDevice, "nil notifyNewDevice means off")
        XCTAssertEqual(loaded.notifications.authorization, .authorized)
        XCTAssertNil(loaded.notifications.deniedHint)
    }

    func testNotificationsSectionReflectsWireKeys() {
        let policy = PolicyDTO(scanOnMount: true, holdUntilScanned: false,
                               notificationThreshold: "warning",
                               notifyUnsafe: false, notifyNewDevice: true)
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: policy)
        XCTAssertFalse(loaded.notifications.notifyUnsafe)
        XCTAssertTrue(loaded.notifications.notifyNewDevice)
    }

    // S1b: denied permission renders a plain hint plus the exact pane deep link.
    func testDeniedAuthorizationCarriesPlainHintAndDeepLink() {
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault,
                                             notificationAuthorization: .denied)
        let hint = loaded.notifications.deniedHint ?? ""
        XCTAssertEqual(hint, "Notifications are off for Plugsight in System Settings. "
                       + "Open Notification settings to turn them on.")
        XCTAssertFalse(hint.contains("\u{2014}"), "no em dashes in shipped prose")
        XCTAssertFalse(hint.contains("UNUserNotificationCenter"), "no internal names")
        XCTAssertEqual(NotificationsSection.notificationSettingsURL,
                       "x-apple.systempreferences:com.apple.preference.notifications")
    }

    func testLoadReadsAuthorizationProvider() async {
        let vm = SettingsViewModel(api: FakeAPIClient(), notificationAuthorization: { .denied },
                                   extensionBundled: { true }, activationError: { nil })
        await vm.load()
        guard case .loaded(let loaded) = vm.state else { return XCTFail("expected loaded") }
        XCTAssertEqual(loaded.notifications.authorization, .denied)
        XCTAssertNotNil(loaded.notifications.deniedHint)
    }

    // The setters write through policy.set, additively.
    func testSetNotifyUnsafeWritesThrough() async {
        let api = FakeAPIClient()
        api.setPolicyResult = .success(PolicyDTO(
            scanOnMount: true, holdUntilScanned: false, notificationThreshold: "warning",
            notifyUnsafe: false, notifyNewDevice: false))
        let vm = SettingsViewModel(api: api)
        await vm.setNotifyUnsafe(false)
        XCTAssertEqual(api.lastPolicy?.notifyUnsafe, false)
        XCTAssertNil(api.lastPolicy?.notifyNewDevice ?? nil, "the other key is left unchanged")
        XCTAssertEqual(api.lastPolicy?.confirm, true)
        XCTAssertNil(vm.notificationsWriteError)
    }

    func testSetNotifyNewDeviceWritesThrough() async {
        let api = FakeAPIClient()
        api.setPolicyResult = .success(PolicyDTO(
            scanOnMount: true, holdUntilScanned: false, notificationThreshold: "warning",
            notifyUnsafe: true, notifyNewDevice: true))
        let vm = SettingsViewModel(api: api)
        await vm.setNotifyNewDevice(true)
        XCTAssertEqual(api.lastPolicy?.notifyNewDevice, true)
        XCTAssertNil(vm.notificationsWriteError)
    }

    // A daemon that predates the keys echoes the policy without them: the write
    // did not take, and the user is told in one plain sentence, never a crash.
    func testOldDaemonEchoWithoutKeysSurfacesPlainError() async {
        let api = FakeAPIClient()  // default echo: Canned.policyDefault, no notify keys
        let vm = SettingsViewModel(api: api)
        await vm.setNotifyUnsafe(false)
        let error = vm.notificationsWriteError ?? ""
        XCTAssertFalse(error.isEmpty, "a silently dropped write must be surfaced")
        XCTAssertTrue(error.contains("newer version of Plugsight"))
        XCTAssertFalse(error.contains("\u{2014}"))
        XCTAssertFalse(error.lowercased().contains("daemon"), "no internal names")
    }

    // A daemon that rejects the write surfaces its own message verbatim.
    func testRejectedNotificationWriteSurfacesAPIErrorMessage() async {
        let api = FakeAPIClient()
        api.setPolicyResult = .failure(APIError(
            kind: .invalidParams, message: "That setting isn't supported yet."))
        let vm = SettingsViewModel(api: api)
        await vm.setNotifyNewDevice(true)
        XCTAssertEqual(vm.notificationsWriteError, "That setting isn't supported yet.")
        vm.dismissNotificationsWriteError()
        XCTAssertNil(vm.notificationsWriteError)
    }

    // Stale definitions is an UPDATE problem, not an install problem: the update
    // command never reinstalls ClamAV, it only refreshes the definitions.
    func testUpdateCommandRunsFreshclamWithoutReinstalling() {
        XCTAssertFalse(SettingsViewModel.scannerUpdateCommand.contains("brew install"),
                       "updating definitions must not reinstall the scanner")
        XCTAssertTrue(SettingsViewModel.scannerUpdateCommand.hasSuffix("freshclam"))
        XCTAssertTrue(SettingsViewModel.scannerInstallCommand.contains("brew install clamav"),
                      "the install flow stays reserved for the not-installed state")
    }

    // The dead 3-level threshold radio group and the painted hold toggle are
    // gone from the model entirely: settings carries exactly the three groups.
    func testNoProtectionGroupRemains() {
        let loaded = SettingsViewModel.build(status: Canned.statusActive, policy: Canned.policyDefault)
        let mirror = Mirror(reflecting: loaded)
        let labels = mirror.children.compactMap(\.label)
        XCTAssertEqual(labels.sorted(), ["notifications", "permissions", "scanner"])
    }
}
