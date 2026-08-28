import XCTest
@testable import PlugsightAppCore

@MainActor
final class PopoverViewModelTests: XCTestCase {

    func testLoadingIsInitial() {
        let vm = PopoverViewModel(api: FakeAPIClient())
        XCTAssertEqual(vm.state, .loading)
    }

    func testNormalOrdersAlertsThenEvents() async {
        let vm = PopoverViewModel(api: FakeAPIClient())
        await vm.load()
        guard case .content(let c) = vm.state else { return XCTFail("expected content, got \(vm.state)") }
        XCTAssertEqual(c.alerts.count, 1)
        XCTAssertEqual(c.events.count, 5)
        XCTAssertFalse(c.isEmpty)
        XCTAssertNil(c.emptySentence)
        if case .normal = c.footer {} else { XCTFail("expected normal footer") }
    }

    // Empty predicate IS the list predicate: sentence renders iff both lists empty.
    func testEmptyStateSentenceMatchesPredicate() async {
        let fake = FakeAPIClient(
            alerts: .success(Canned.alertsEmpty),
            tail: .success(EventSubscriptionDTO(subscriptionId: "sub_1")))
        fake.timelineResult = .success(Canned.timelineEmpty)
        let vm = PopoverViewModel(api: fake)
        await vm.load()
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.emptySentence, "Monitoring. Nothing has plugged in yet.")
        // The predicate the view uses is exactly alerts.isEmpty && events.isEmpty.
        XCTAssertEqual(c.isEmpty, c.alerts.isEmpty && c.events.isEmpty)
    }

    func testDegradedFooterNamesMissingGrant() async {
        let fake = FakeAPIClient(status: .success(Canned.statusDegraded))
        let vm = PopoverViewModel(api: fake)
        await vm.load()
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        guard case .degraded(let grant) = c.footer else { return XCTFail("expected degraded footer") }
        XCTAssertEqual(grant, "Input Monitoring")
    }

    func testStoppedState() async {
        let fake = FakeAPIClient(status: .success(Canned.statusStopped))
        let vm = PopoverViewModel(api: fake)
        await vm.load()
        guard case .stopped = vm.state else { return XCTFail("expected stopped, got \(vm.state)") }
    }

    func testDaemonUnreachableBecomesStopped() async {
        let fake = FakeAPIClient(status: .failure(.daemonUnreachable))
        let vm = PopoverViewModel(api: fake)
        await vm.load()
        guard case .stopped = vm.state else { return XCTFail("expected stopped") }
    }

    func testStoreErrorState() async {
        let fake = FakeAPIClient()
        fake.timelineResult = .failure(APIError(kind: .storeUnreadable, message: "Can't read the event record"))
        let vm = PopoverViewModel(api: fake)
        await vm.load()
        guard case .storeError(let msg) = vm.state else { return XCTFail("expected storeError") }
        XCTAssertEqual(msg, "Can't read the event record")
    }

    // At-scale: alerts cap at 3 + "and N more"; events stay 5.
    func testAtScaleCapsAlertsAtThree() async {
        let fake = FakeAPIClient(alerts: .success(Canned.alertsMany))
        fake.timelineResult = .success(Canned.timelineAtScale)
        let vm = PopoverViewModel(api: fake)
        await vm.load()
        guard case .content(let c) = vm.state else { return XCTFail("expected content") }
        XCTAssertEqual(c.alerts.count, 3)
        XCTAssertEqual(c.moreAlertsCount, 2)
        XCTAssertEqual(c.events.count, 5)
    }
}
