// CrossDecodeParityTests.swift
//
// The PERMANENT cross-decode parity gate (node N-API-PARITY). The three views of
// the local API drifted once (the daemon's wire output, the UI DTOs, the 03/N9
// contract) because each side tested against its OWN canned payloads — the unit
// gates never fed the daemon's REAL bytes to the UI decoder. This test closes
// that hole for good:
//
//   for EACH method: build the daemon's actual result object via Router/APITypes,
//   JSON-encode it exactly as the wire encodes it, then DECODE it with the
//   corresponding PlugsightAppCore UI DTO. Assert no decode error and that the
//   key fields survived the round trip.
//
// If the daemon and the UI ever disagree on a field name or type again, the
// decode throws and this test fails — the drift can no longer ship silently.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightAppCore
import PlugsightCore

@MainActor
final class CrossDecodeParityTests: XCTestCase {

    // The daemon encodes results with this exact configuration (JSONRPC.swift).
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private let decoder = JSONDecoder()

    /// Encode a daemon result the way the wire does, then decode it as the UI DTO.
    /// Any field-name/type drift surfaces here as a thrown DecodingError.
    @discardableResult
    private func crossDecode<D: Encodable, U: Decodable>(
        _ daemon: D, as ui: U.Type, file: StaticString = #filePath, line: UInt = #line
    ) throws -> U {
        let data = try encoder.encode(daemon)
        do {
            return try decoder.decode(U.self, from: data)
        } catch {
            let json = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            XCTFail("UI \(U.self) failed to decode the daemon wire shape: \(error)\nwire: \(json)",
                    file: file, line: line)
            throw error
        }
    }

    // MARK: - Fixture: one seeded daemon over a temp DB + a Router in front of it

    private struct Fixture {
        let router: Router
        let store: APIStore
        let deviceID: String
        let eventID: String
        let alertID: String
        let scanID: String
        let runningScanID: String
        let quarantineID: String
    }

    private func makeFixture(inputMonitoring: Bool = true) throws -> Fixture {
        let dir = "/tmp/ps-parity-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dbPath = (dir as NSString).appendingPathComponent("plugsight.db")
        let event = try EventStore(path: dbPath)
        let store = try APIStore(store: event)

        // A composite keyboard device.
        let upsert = try event.upsertDevice(from: DeviceDescriptor(
            deviceKey: "k1", vid: 0x046d, pid: 0xc52b, serial: "KB-SERIAL-123",
            vendorName: "Logitech", productName: "Logitech USB Receiver",
            interfaces: [InterfaceDescriptor(seq: 0, usbClass: 0x03, usbSubclass: 0, usbProtocol: 1)],
            portPath: "20-2.4"))
        let deviceID = upsert.deviceID

        // device.attached carries the port path (topology derives from it).
        _ = try event.appendEvent(kind: "device.attached", severity: "info", deviceID: deviceID,
            summary: "Logitech USB Receiver plugged in. Presents as: keyboard.",
            detail: #"{"v":1,"portPath":"20-2.4"}"#)
        // trust.changed feeds the device's trust history (with actor + note).
        _ = try event.appendEvent(kind: "trust.changed", severity: "info", deviceID: deviceID,
            actor: "ui", summary: "Trust set to trusted by ui. 'my keyboard'",
            detail: #"{"v":1,"from":"none","to":"trusted","note":"my keyboard"}"#)
        // A monitoring gap event (rendered as a gap row by the UI timeline).
        _ = try event.appendEvent(kind: "monitoring.gap", severity: "notice", deviceID: nil,
            summary: "Monitoring was off between 02:14 and 08:03.",
            detail: #"{"v":1,"from":"2026-08-25T02:14:00.000Z","to":"2026-08-25T08:03:00.000Z"}"#)
        // The event explain_event/timeline exercise.
        let eventID = try event.appendEvent(kind: "hid.typing_burst", severity: "warning",
            deviceID: deviceID, summary: "Typed 47 keys in 1.1 seconds.",
            detail: #"{"v":1,"keys":47,"ms":1100}"#)

        // A behavioral score snapshot.
        try store.seedScore(deviceID: deviceID, score: 78, confidence: "medium",
            signals: #"[{"id":"plug_to_type_latency","observed":"410ms","verdict":"suspicious","weight":0.35}]"#)

        // An ACTIVE alert (alerts.list + alerts.ack).
        let alertID = "alr_parity1"
        try store.seedAlert(id: alertID, deviceID: deviceID, rule: "R1", severity: "critical",
            state: "active", summary: "Presented as a charger, but also a keyboard.",
            why: "R1 mismatch: charger + HID keyboard on one device.")

        // An infected scan with a quarantined finding (scan.get quarantine record).
        let scan = try store.insertScan(deviceID: deviceID, volumePath: "/Volumes/UNTITLED",
            engine: "clamdscan", startedBy: "system")
        try store.setScanState(id: scan.id, state: "infected", filesScanned: 128, finishedAt: Date())
        try store.seedFinding(scanID: scan.id, filePath: "/Volumes/UNTITLED/evil.exe",
            signature: "Win.Trojan.Test", action: "quarantined", quarantinePath: "/q/abc123")

        // A RUNNING scan so scan.cancel has a non-terminal target to cancel.
        let running = try store.insertScan(deviceID: deviceID, volumePath: "/Volumes/UNTITLED",
            engine: "clamdscan", startedBy: "system")

        let router = Router(
            store: store, broadcaster: EventBroadcaster(), daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: inputMonitoring, endpointSecurity: true, clamav: true),
            startedAt: Date(), quarantineDirectory: (dir as NSString).appendingPathComponent("quarantine"))

        return Fixture(router: router, store: store, deviceID: deviceID, eventID: eventID,
                       alertID: alertID, scanID: scan.id, runningScanID: running.id, quarantineID: "abc123")
    }

    // Local decode structs for the nested write-result shapes.
    private struct AckWire: Decodable { let alert: PlugsightAppCore.AlertDTO; let event: PlugsightAppCore.EventDTO }
    private struct TrustWire: Decodable { let device: PlugsightAppCore.DeviceDetailDTO; let event: PlugsightAppCore.EventDTO; let caveat: String }

    // MARK: - Read methods

    func testStatusGetDecodesAsStatusDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.statusGet(), as: StatusDTO.self)
        XCTAssertEqual(ui.daemonVersion, "1.0.0")
        // The additive scanner install fields survive the round trip. This
        // fixture's Router wires no installer, so the state is idle with no
        // detail — the shape (a decodable installState) is what parity guards.
        XCTAssertEqual(ui.scanner.installState, .idle)
        XCTAssertNil(ui.scanner.installDetail)
    }

    func testStatusGetDecodesNonIdleInstallAndDefsAge() throws {
        // The idle case is covered above; this proves a NON-idle installState, a
        // populated installDetail, and a non-nil definitionsAgeDays survive the
        // wire. A brew-missing installer lands installState=failed with a detail;
        // the defs resolver yields a concrete age.
        let f = try makeFixture()
        let failingInstaller = ScannerInstaller(brewLocator: { nil },
                                                runAsync: { _ in })
        _ = failingInstaller.startInstall()   // -> failed + homebrew-missing detail
        let router = Router(
            store: f.store, broadcaster: EventBroadcaster(), daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
            startedAt: Date(), quarantineDirectory: "/tmp/ps-parity-status/quarantine",
            definitionsAgeResolver: { 3 },
            scannerInstaller: failingInstaller)

        let ui = try crossDecode(router.statusGet(), as: StatusDTO.self)
        XCTAssertEqual(ui.scanner.installState, .failed,
                       "a non-idle installState must survive the wire, not fall back to idle")
        XCTAssertNotNil(ui.scanner.installDetail)
        XCTAssertTrue(ui.scanner.installDetail?.contains("Homebrew") == true,
                      "the install detail crosses the wire intact")
        XCTAssertEqual(ui.scanner.definitionsAgeDays, 3,
                       "a non-nil definitionsAgeDays must survive the wire")
    }

    func testStatusGetDecodesInstallingState() throws {
        // The `installing` state (with its live detail) also round-trips.
        let f = try makeFixture()
        let installer = ScannerInstaller(
            brewLocator: { "/opt/homebrew/bin/brew" },
            runAsync: { _ in })   // capture the work but never run it: stays installing
        _ = installer.startInstall()
        let router = Router(
            store: f.store, broadcaster: EventBroadcaster(), daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: true),
            startedAt: Date(), quarantineDirectory: "/tmp/ps-parity-status/quarantine",
            scannerInstaller: installer)
        let ui = try crossDecode(router.statusGet(), as: StatusDTO.self)
        XCTAssertEqual(ui.scanner.installState, .installing)
        XCTAssertEqual(ui.scanner.installDetail, "Installing ClamAV...")
    }

    func testDevicesListDecodesAsDeviceListDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.devicesList(DevicesListParams(filter: nil, limit: nil, cursor: nil)),
                                 as: DeviceListDTO.self)
        XCTAssertEqual(ui.devices.count, 1)
        XCTAssertEqual(ui.devices.first?.deviceId, f.deviceID)
        XCTAssertEqual(ui.devices.first?.interfaceClasses, ["keyboard"])
    }

    func testDevicesListSafetyStatusCrossDecodes() throws {
        // The derived verdict rides on every devices.list row and decodes into
        // the UI's SafetyStatusDTO: status word + reasons with id/sentence/action.
        let f = try makeFixture()
        let ui = try crossDecode(f.router.devicesList(DevicesListParams(filter: nil, limit: nil, cursor: nil)),
                                 as: DeviceListDTO.self)
        let status = try XCTUnwrap(ui.devices.first?.safetyStatus,
                                   "devices.list rows carry safetyStatus")
        XCTAssertTrue(["green", "yellow", "red", "grey"].contains(status.status))
        let reason = try XCTUnwrap(status.reasons.first, "at least one reason, always")
        XCTAssertFalse(reason.id.isEmpty)
        XCTAssertFalse(reason.sentence.isEmpty)
        XCTAssertFalse(reason.action.isEmpty)
    }

    func testDevicesGetSafetyStatusMatchesListDerivation() throws {
        let f = try makeFixture()
        let list = try crossDecode(f.router.devicesList(DevicesListParams(filter: nil, limit: nil, cursor: nil)),
                                   as: DeviceListDTO.self)
        let detail = try crossDecode(f.router.devicesGet(DeviceGetParams(deviceId: f.deviceID)),
                                     as: DeviceDetailDTO.self)
        XCTAssertEqual(detail.safetyStatus, list.devices.first?.safetyStatus,
                       "devices.get and devices.list tell the same verdict story")
    }

    func testDevicesListCarriesScanningLastScanAndActiveAlerts() throws {
        // Device-summary truthfulness: an in-flight scan surfaces as
        // scanning=true, lastScan reports the most recent scan's state and finish
        // time, and activeAlerts survives the round trip. The fixture seeds one
        // RUNNING scan (newest) and one active alert.
        let f = try makeFixture()
        var ui = try crossDecode(f.router.devicesList(DevicesListParams(filter: nil, limit: nil, cursor: nil)),
                                 as: DeviceListDTO.self)
        var d = try XCTUnwrap(ui.devices.first)
        XCTAssertEqual(d.scanning, true, "an in-flight scan must surface as scanning=true")
        XCTAssertEqual(d.lastScan?.state, .running)
        XCTAssertNil(d.lastScan?.finishedAt)
        XCTAssertEqual(d.activeAlerts, 1, "activeAlerts must round-trip")

        // Finish the running scan: scanning drops, lastScan turns terminal.
        try f.store.setScanState(id: f.runningScanID, state: "clean", filesScanned: 10, finishedAt: Date())
        ui = try crossDecode(f.router.devicesList(DevicesListParams(filter: nil, limit: nil, cursor: nil)),
                             as: DeviceListDTO.self)
        d = try XCTUnwrap(ui.devices.first)
        XCTAssertEqual(d.scanning, false, "no in-flight scan means scanning=false, not a stuck spinner")
        XCTAssertEqual(d.lastScan?.state, .clean)
        XCTAssertNotNil(d.lastScan?.finishedAt)
    }

    func testDevicesGetCarriesScanningAndLastScan() throws {
        // devices.get tells the same story as devices.list (daemon-side shape;
        // the app's detail DTO ignores fields it does not render yet).
        let f = try makeFixture()
        let record = try f.router.devicesGet(DeviceGetParams(deviceId: f.deviceID))
        XCTAssertTrue(record.scanning)
        XCTAssertEqual(record.lastScan?.state, "running")
        XCTAssertEqual(record.lastScan?.scanId, f.runningScanID)
    }

    func testDevicesGetDecodesAsDeviceDetailDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.devicesGet(DeviceGetParams(deviceId: f.deviceID)),
                                 as: DeviceDetailDTO.self)
        XCTAssertEqual(ui.deviceId, f.deviceID)
        // Interface raw codes decode via class/subclass/protocol + role + seq.
        XCTAssertEqual(ui.interfaces.first?.usbClass, 3)
        XCTAssertEqual(ui.interfaces.first?.role, "keyboard")
        // Derived fields the UI needs and the daemon used to omit.
        XCTAssertEqual(ui.trustHistory.first?.tier, "trusted")
        XCTAssertEqual(ui.trustHistory.first?.actor, "ui")
        XCTAssertEqual(ui.trustHistory.first?.note, "my keyboard")
        XCTAssertEqual(ui.topology?.port, "20-2.4")
        XCTAssertEqual(ui.topology?.hubPath, ["2", "4"])
        XCTAssertFalse(ui.isStorage)
    }

    func testTimelineListDecodesAsTimelineDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.timelineList(TimelineListParams(filter: nil, limit: nil, cursor: nil)),
                                 as: TimelineDTO.self)
        // The monitoring.gap event rides in the events list (no separate gaps field).
        XCTAssertTrue(ui.events.contains { $0.kind == "monitoring.gap" })
        // And the UI renders it as a gap row.
        let rows = TimelineViewModel.rows(from: ui)
        XCTAssertTrue(rows.contains { if case .gap = $0 { return true } else { return false } })
        // The gap's structured detail survives the wire and formats as LOCAL
        // wall-clock text (defect 6: no raw UTC ISO stamps on screen).
        let gap = try XCTUnwrap(ui.events.first { $0.kind == "monitoring.gap" })
        XCTAssertNotNil(gap.detail, "timeline rows carry the stored detail")
        let utc = TimeZone(identifier: "UTC")!
        let from = TimeFormatting.timeOnly("2026-08-25T02:14:00.000Z", timeZone: utc)
        let to = TimeFormatting.timeOnly("2026-08-25T08:03:00.000Z", timeZone: utc)
        XCTAssertEqual(GapVocabulary.displaySummary(gap, timeZone: utc),
                       "Monitoring was off between \(from) and \(to).")
        XCTAssertTrue(from.hasPrefix("2:14"))
    }

    func testEventsGetDecodesAsEventExplanationDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.eventsGet(EventGetParams(eventId: f.eventID)),
                                 as: EventExplanationDTO.self)
        XCTAssertEqual(ui.event.eventId, f.eventID)
        XCTAssertFalse(ui.why.isEmpty)
        XCTAssertFalse(ui.suggestedActions.isEmpty)
    }

    func testScoreGetDecodesAsScoreDTO_sensorOn() throws {
        let f = try makeFixture(inputMonitoring: true)
        let ui = try crossDecode(f.router.scoreGet(ScoreGetParams(deviceId: f.deviceID)),
                                 as: ScoreDTO.self)
        XCTAssertEqual(ui.score, 78)
        XCTAssertTrue(ui.sensorAvailable)
        XCTAssertEqual(DeviceInspectorViewModel.behaviorCard(from: ui).showsNumber, true)
    }

    func testScoreGetDecodesAsScoreDTO_sensorOff() throws {
        // Input Monitoring off: null-not-zero, and sensorAvailable=false so the UI
        // says "sensor off", not a fabricated 0.
        let f = try makeFixture(inputMonitoring: false)
        let ui = try crossDecode(f.router.scoreGet(ScoreGetParams(deviceId: f.deviceID)),
                                 as: ScoreDTO.self)
        XCTAssertNil(ui.score)
        XCTAssertFalse(ui.sensorAvailable)
        if case .sensorOff = DeviceInspectorViewModel.behaviorCard(from: ui) {} else {
            XCTFail("sensor-off score must map to the sensorOff card, not a number")
        }
    }

    func testAlertsListDecodesAsAlertListDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.alertsList(AlertsListParams(filter: nil, limit: nil, cursor: nil)),
                                 as: AlertListDTO.self)
        let a = try XCTUnwrap(ui.alerts.first)
        XCTAssertEqual(a.alertId, f.alertID)
        XCTAssertFalse(a.deviceName.isEmpty)     // resolved device name the UI needs
        XCTAssertFalse(a.at.isEmpty)             // timestamp field
        XCTAssertFalse(a.suggestedActions.isEmpty)
    }

    func testScanGetDecodesAsScanDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.scanGet(ScanGetParams(scanId: f.scanID)),
                                 as: PlugsightAppCore.ScanDTO.self)
        XCTAssertEqual(ui.state, .infected)
        XCTAssertEqual(ui.verdicts.first?.verdict, "infected")
        XCTAssertEqual(ui.quarantine.first?.quarantineId, f.quarantineID)
        XCTAssertEqual(ui.quarantine.first?.containment, "quarantined")
    }

    func testScansListDecodesAsScanSummaryList() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.scansList(ScansListParams(filter: nil, limit: nil, cursor: nil)),
                                 as: ScanListDTO.self)
        let infected = try XCTUnwrap(ui.scans.first { $0.scanId == f.scanID })
        XCTAssertEqual(infected.state, .infected)
        // Scan rows carry their facts: times survive the wire, and reason is nil
        // for states whose word already says it (infected/running).
        XCTAssertFalse(infected.startedAt.isEmpty)
        XCTAssertNotNil(infected.finishedAt)
        XCTAssertNil(infected.reason)
    }

    func testScansListCarriesReasonForFailedAndSkippedScans() throws {
        // A failed/skipped summary row must carry a non-blank reason sentence
        // (5c/5f) so the list can say WHY without a scan.get round trip.
        let f = try makeFixture()
        let failed = try f.store.insertScan(deviceID: f.deviceID, volumePath: "/Volumes/UNTITLED",
                                            engine: "clamdscan", startedBy: "system")
        try f.store.setScanState(id: failed.id, state: "failed", filesScanned: 0, finishedAt: Date())
        let skipped = try f.store.insertScan(deviceID: f.deviceID, volumePath: "/Volumes/UNTITLED",
                                             engine: "clamdscan", startedBy: "system")
        try f.store.setScanState(id: skipped.id, state: "skipped", filesScanned: 0, finishedAt: Date())

        let ui = try crossDecode(f.router.scansList(ScansListParams(filter: nil, limit: nil, cursor: nil)),
                                 as: ScanListDTO.self)
        let failedRow = try XCTUnwrap(ui.scans.first { $0.scanId == failed.id })
        XCTAssertEqual(failedRow.state, .failed)
        XCTAssertEqual(failedRow.reason?.isEmpty, false, "a failed row carries a non-blank reason")
        let skippedRow = try XCTUnwrap(ui.scans.first { $0.scanId == skipped.id })
        XCTAssertEqual(skippedRow.reason?.isEmpty, false, "a skipped row carries a non-blank reason")
    }

    func testPolicyGetDecodesAsPolicyDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.policyGet(), as: PolicyDTO.self)
        // The canonical wire keys the UI maps its display labels onto.
        XCTAssertFalse(ui.holdUntilScanned)
        XCTAssertEqual(ui.notificationThreshold, "warning")
    }

    func testScanStartDecodesAsScanStartedDTO() throws {
        // scan.start returns a small {scanId, state} shape (03).
        let ui = try crossDecode(ScanStartResult(scanId: "scn_x", state: "running"),
                                 as: ScanStartedDTO.self)
        XCTAssertEqual(ui.scanId, "scn_x")
        XCTAssertEqual(ui.state, .running)
    }

    func testScanCancelDecodesAsScanDTO() throws {
        let f = try makeFixture()
        let ui = try crossDecode(f.router.scanCancel(ScanCancelParams(scanId: f.runningScanID)),
                                 as: PlugsightAppCore.ScanDTO.self)
        XCTAssertEqual(ui.state, .canceled)
    }

    func testPolicySetDecodesAsPolicyDTO() throws {
        let f = try makeFixture()
        // A no-op partial policy round-trips the full canonical object.
        let ui = try crossDecode(try f.router.policySet(.object([:]), actor: "ui"), as: PolicyDTO.self)
        XCTAssertEqual(ui.notificationThreshold, "warning")
    }

    // MARK: - Live event subscription (events.tail / events.untail / event.appended)

    func testEventsTailDecodesAsEventSubscriptionDTO() throws {
        // events.tail returns the subscription id (02 subscription model) — the UI
        // decodes {subscriptionId}, NOT an EventBatch.
        let ui = try crossDecode(EventsTailResult(subscriptionId: "sub_1"),
                                 as: EventSubscriptionDTO.self)
        XCTAssertEqual(ui.subscriptionId, "sub_1")
    }

    func testEventsUntailDecodesAsUntailResultDTO() throws {
        let ui = try crossDecode(EventsUntailResult(ok: true), as: UntailResultDTO.self)
        XCTAssertTrue(ui.ok)
    }

    func testEventAppendedNotificationDecodesAsEventDTO() throws {
        // The daemon pushes `event.appended` notifications whose params are a
        // TimelineEvent; the UI decodes each as an EventDTO. Built from the real
        // Router mapping of a stored event.
        let f = try makeFixture()
        let stored = try XCTUnwrap(try f.store.getEvent(id: f.eventID))
        let ui = try crossDecode(Router.timelineEvent(from: stored), as: EventDTO.self)
        XCTAssertEqual(ui.eventId, f.eventID)
        XCTAssertEqual(ui.kind, "hid.typing_burst")
    }

    // MARK: - Write methods (nested results)

    func testAlertsAckDecodesNestedAlertAndEvent() throws {
        let f = try makeFixture()
        let result = try f.router.alertsAck(AlertsAckParams(alertId: f.alertID, comment: "seen"), actor: "ui")
        let ui = try crossDecode(result, as: AckWire.self)
        XCTAssertEqual(ui.alert.state, "acknowledged")
        XCTAssertEqual(ui.event.kind, "alert.acknowledged")
    }

    func testTrustSetDecodesNestedDeviceEventCaveat() throws {
        let f = try makeFixture()
        let result = try f.router.trustSet(TrustSetParams(deviceId: f.deviceID, tier: "trusted", note: "mine"), actor: "ui")
        let ui = try crossDecode(result, as: TrustWire.self)
        XCTAssertEqual(ui.device.trust, "trusted")
        XCTAssertEqual(ui.event.kind, "trust.changed")
        XCTAssertFalse(ui.caveat.isEmpty)
    }

    func testQuarantineRestoreResultDecodes() throws {
        // The restore result shape (03 D6): built directly since driving the real
        // file mover needs an on-disk quarantine slot.
        let event = TimelineEvent(eventId: "evt_r", at: "2026-08-25T09:25:00.000Z",
            kind: "quarantine.restored", severity: "notice", deviceId: "dev_1",
            summary: "Restored 'invoice.pdf' from quarantine.", actor: "ui")
        let daemon = QuarantineRestoreResult(
            quarantineId: "abc123", scanId: "scn_1", deviceId: "dev_1",
            originalPath: "/Volumes/USB/invoice.pdf", signature: "Eicar-Test-Signature",
            state: "restored",
            risk: "You are restoring a file ClamAV flagged; only do this if you are certain it is a false positive.",
            event: event)
        let ui = try crossDecode(daemon, as: QuarantineRestoreResultDTO.self)
        XCTAssertEqual(ui.state, "restored")
        XCTAssertEqual(ui.originalPath, "/Volumes/USB/invoice.pdf")
        XCTAssertFalse(ui.risk.isEmpty)
    }
}
