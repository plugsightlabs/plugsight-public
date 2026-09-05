import XCTest
@testable import PlugsightAppCore

@MainActor
final class PopoverViewModelTests: XCTestCase {

    /// Fixed timezone so the local-time assertions are deterministic.
    private let utc = TimeZone(identifier: "UTC")!

    func testLoadingIsInitial() {
        let vm = PopoverViewModel(api: FakeAPIClient())
        XCTAssertEqual(vm.state, .loading)
    }

    func testNormalOrdersAlertsThenEvents() async {
        let vm = PopoverViewModel(api: FakeAPIClient())
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content, got \(vm.state)") }
        XCTAssertEqual(c.alerts.count, 1)
        XCTAssertEqual(c.events.count, 5)
        XCTAssertFalse(c.isEmpty)
        XCTAssertNil(c.emptySentence)
        if case .normal = c.footer {} else { XCTFail("expected normal footer") }
    }

    // The verdict line: no active alerts reads "All devices safe"; alerts count
    // the DISTINCT devices needing attention, with singular/plural grammar.
    func testVerdictAllSafeWhenNoActiveAlerts() async {
        let fake = FakeAPIClient(alerts: .success(Canned.alertsEmpty))
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        XCTAssertEqual(c.verdict, .allSafe)
        XCTAssertEqual(c.verdict.word, "All devices safe")
        XCTAssertEqual(c.verdict.safetyStatus, "green")
    }

    func testVerdictCountsDistinctDevicesNeedingAttention() async {
        let one = PopoverViewModel(api: FakeAPIClient())  // one alert, one device
        await one.load(timeZone: utc)
        guard case .content(let c1) = one.state else { return XCTFail("expected content") }
        XCTAssertEqual(c1.verdict, .needsAttention(count: 1))
        XCTAssertEqual(c1.verdict.word, "1 needs attention")

        let many = PopoverViewModel(api: FakeAPIClient(alerts: .success(Canned.alertsMany)))
        await many.load(timeZone: utc)
        guard case .content(let c5) = many.state else { return XCTFail("expected content") }
        XCTAssertEqual(c5.verdict, .needsAttention(count: 5))
        XCTAssertEqual(c5.verdict.word, "5 need attention")
        XCTAssertEqual(c5.verdict.safetyStatus, "yellow")
    }

    // Rows carry LOCAL times through the shared TimeFormatting helper.
    func testRowsCarryLocalTimes() async {
        let vm = PopoverViewModel(api: FakeAPIClient())
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        // Canned alert alt_1 is at 2026-08-25T09:14:02Z. Contains-checks avoid
        // asserting the exact space character the formatter uses before AM.
        XCTAssertEqual(c.alerts.first?.time, TimeFormatting.timeOnly("2026-08-25T09:14:02Z", timeZone: utc))
        XCTAssertTrue(c.alerts.first?.time.contains("9:14") == true,
                      "expected the local wall-clock 9:14, got '\(c.alerts.first?.time ?? "")'")
        // Canned timeline evt_5 is at 2026-08-25T09:14:02Z.
        XCTAssertTrue(c.events.first?.time.contains("9:14") == true,
                      "expected the local wall-clock 9:14, got '\(c.events.first?.time ?? "")'")
    }

    // The Details route needs the alert's device id.
    func testAlertRowsCarryDeviceId() async {
        let vm = PopoverViewModel(api: FakeAPIClient())
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        XCTAssertEqual(c.alerts.first?.deviceId, "dev_charger")
    }

    // Empty split, branch 1: devices are known (footer counts them), so the
    // empty sentence may not claim "nothing has plugged in yet".
    func testEmptyWithKnownDevicesSaysNothingConnectedNow() async {
        let fake = FakeAPIClient(
            alerts: .success(Canned.alertsEmpty),
            tail: .success(EventSubscriptionDTO(subscriptionId: "sub_1")))
        fake.timelineResult = .success(Canned.timelineEmpty)
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        XCTAssertTrue(c.isEmpty)
        XCTAssertTrue(c.devicesKnown)
        XCTAssertEqual(c.emptySentence, "Nothing is connected right now.")
        // The predicate the view uses is exactly alerts.isEmpty && events.isEmpty.
        XCTAssertEqual(c.isEmpty, c.alerts.isEmpty && c.events.isEmpty)
    }

    // Empty split, branch 2: truly nothing ever (no devices on record either)
    // keeps the first-run sentence.
    func testEmptyWithNoDevicesEverKeepsFirstRunSentence() async {
        var status = Canned.statusActive
        status.devicesPresent = 0
        let fake = FakeAPIClient(
            status: .success(status),
            devices: .success(Canned.devicesEmpty),
            alerts: .success(Canned.alertsEmpty),
            tail: .success(EventSubscriptionDTO(subscriptionId: "sub_1")))
        fake.timelineResult = .success(Canned.timelineEmpty)
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        XCTAssertTrue(c.isEmpty)
        XCTAssertFalse(c.devicesKnown)
        XCTAssertEqual(c.emptySentence, "Monitoring. Nothing has plugged in yet.")
    }

    // Historical-only record: nothing connected, but the record knows devices.
    func testEmptyWithHistoricalDevicesOnRecordSaysNothingConnected() async {
        var status = Canned.statusActive
        status.devicesPresent = 0
        let fake = FakeAPIClient(
            status: .success(status),
            devices: .success(DeviceListDTO(
                devices: [Canned.devicesNormal.devices.first { !$0.present }!],
                nextCursor: nil)),
            alerts: .success(Canned.alertsEmpty),
            tail: .success(EventSubscriptionDTO(subscriptionId: "sub_1")))
        fake.timelineResult = .success(Canned.timelineEmpty)
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        XCTAssertEqual(c.emptySentence, "Nothing is connected right now.")
    }

    func testDegradedFooterNamesMissingGrant() async {
        let fake = FakeAPIClient(status: .success(Canned.statusDegraded))
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        guard case .degraded(let grant) = c.footer else { return XCTFail("expected degraded footer") }
        XCTAssertEqual(grant, "Input Monitoring")
    }

    // Footer honesty: when the ONLY missing grant is a system extension the
    // build does not ship, the footer shows the normal monitoring line (the
    // extension is not installable; a permanent degraded banner would be a lie).
    func testUnbundledExtensionAloneKeepsNormalFooter() async {
        let status = StatusDTO(
            monitoring: .degraded, daemonVersion: "1.0.0",
            permissions: .init(inputMonitoring: true, inputMonitoringSensor: "active",
                               esExtension: .inactive),
            scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2,
                           installState: .done, installDetail: nil),
            devicesPresent: 3, activeAlerts: 0, monitoringGaps: [])
        let fake = FakeAPIClient(status: .success(status))
        let vm = PopoverViewModel(api: fake, extensionBundled: false)
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        guard case .normal(let text) = c.footer else {
            return XCTFail("expected normal footer, got \(c.footer)")
        }
        XCTAssertEqual(text, "Monitoring 3 devices.")
    }

    // But missing Input Monitoring or scanner still degrade, bundled or not.
    func testUnbundledExtensionStillDegradesForOtherMissingGrants() async {
        let fake = FakeAPIClient(status: .success(Canned.statusDegraded))
        let vm = PopoverViewModel(api: fake, extensionBundled: false)
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        guard case .degraded(let grant) = c.footer else { return XCTFail("expected degraded footer") }
        XCTAssertEqual(grant, "Input Monitoring")
    }

    func testStoppedState() async {
        let fake = FakeAPIClient(status: .success(Canned.statusStopped))
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .stopped(let msg) = vm.state else { return XCTFail("expected stopped, got \(vm.state)") }
        XCTAssertEqual(msg, PopoverViewModel.stoppedSupport)
    }

    // The stopped copy must be truthful (live-walk defect 5): Plugsight is the
    // app SHOWING the message, so it must never say "Plugsight isn't running,
    // start it from your Applications folder" — the daemon is what is off, and
    // the recovery is the Start monitoring button beside the text.
    func testDaemonUnreachableBecomesStoppedWithTruthfulCopy() async {
        let fake = FakeAPIClient(status: .failure(.daemonUnreachable))
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .stopped(let msg) = vm.state else { return XCTFail("expected stopped") }
        XCTAssertEqual(msg, PopoverViewModel.stoppedSupport)
        XCTAssertFalse(msg.contains("Applications folder"), "the old copy lied in this surface")
        XCTAssertFalse(PopoverViewModel.stoppedTitle.contains("Plugsight isn"))
    }

    // A post-update start failure replaces the supporting line with the honest
    // advisory the shell sets (defect 8), for both stopped shapes.
    func testStartAdvisoryReplacesStoppedSupport() async {
        let fake = FakeAPIClient(status: .failure(.daemonUnreachable))
        let vm = PopoverViewModel(api: fake)
        vm.startAdvisory = DaemonStartSupervisor.updateAdvisory
        await vm.load(timeZone: utc)
        guard case .stopped(let msg) = vm.state else { return XCTFail("expected stopped") }
        XCTAssertEqual(msg, DaemonStartSupervisor.updateAdvisory)
    }

    func testStoreErrorState() async {
        let fake = FakeAPIClient()
        fake.timelineResult = .failure(APIError(kind: .storeUnreadable, message: "Can't read the event record"))
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .storeError(let msg) = vm.state else { return XCTFail("expected storeError") }
        XCTAssertEqual(msg, "Can't read the event record")
    }

    // At-scale: alerts cap at 3 + "and N more"; events stay 5.
    func testAtScaleCapsAlertsAtThree() async {
        let fake = FakeAPIClient(alerts: .success(Canned.alertsMany))
        fake.timelineResult = .success(Canned.timelineAtScale)
        let vm = PopoverViewModel(api: fake)
        await vm.load(timeZone: utc)
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        XCTAssertEqual(c.alerts.count, 3)
        XCTAssertEqual(c.moreAlertsCount, 2)
        XCTAssertEqual(c.events.count, 5)
    }
}
