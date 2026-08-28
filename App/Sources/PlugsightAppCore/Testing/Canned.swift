// Canned.swift
//
// The single fixture set the unit tests assert on and the snapshot generator
// draws. Every payload is written to match 03's JSON shapes and 04's plain-
// language copy. The at-scale seeds (20 devices, a few hundred events) drive the
// conference-dock screenshots the visual gate reviews.

import Foundation

public enum Canned {

    // MARK: - status

    public static let statusActive = StatusDTO(
        monitoring: .active,
        daemonVersion: "1.0.0",
        permissions: .init(inputMonitoring: true, esExtension: .active),
        scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2),
        devicesPresent: 4,
        activeAlerts: 1,
        monitoringGaps: []
    )

    /// Input Monitoring missing → typing-behavior scoring off (1b/4b).
    public static let statusDegraded = StatusDTO(
        monitoring: .degraded,
        daemonVersion: "1.0.0",
        permissions: .init(inputMonitoring: false, esExtension: .active),
        scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2),
        devicesPresent: 3,
        activeAlerts: 0,
        monitoringGaps: []
    )

    public static let statusStopped = StatusDTO(
        monitoring: .stopped,
        daemonVersion: "1.0.0",
        permissions: .init(inputMonitoring: true, esExtension: .active),
        scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2),
        devicesPresent: 0,
        activeAlerts: 0,
        monitoringGaps: [.init(from: "2026-08-25T02:14:00Z", to: "2026-08-25T08:03:00Z")]
    )

    /// Scanner absent + definitions age unknown → Settings scanner states (5c).
    public static let statusScannerMissing = StatusDTO(
        monitoring: .active,
        daemonVersion: "1.0.0",
        permissions: .init(inputMonitoring: true, esExtension: .inactive),
        scanner: .init(available: false, engine: nil, definitionsAgeDays: nil),
        devicesPresent: 2,
        activeAlerts: 0,
        monitoringGaps: []
    )

    // MARK: - devices

    public static let devicesNormal = DeviceListDTO(devices: [
        DeviceSummaryDTO(deviceId: "dev_sandisk", name: "SanDisk Ultra", present: true,
            firstSeen: "2026-08-25T09:10:00Z", lastSeen: "2026-08-25T09:14:00Z",
            vidPid: "0781:5581", serial: "AA010203", interfaceClasses: ["mass_storage"],
            trust: "none", score: nil, activeAlerts: 0, scanning: true),
        DeviceSummaryDTO(deviceId: "dev_logi", name: "Logitech USB Receiver", present: true,
            firstSeen: "2026-08-20T08:00:00Z", lastSeen: "2026-08-25T09:00:00Z",
            vidPid: "046d:c52b", serial: nil, interfaceClasses: ["hid_keyboard", "hid_mouse"],
            trust: "trusted", score: .init(value: 4, confidence: "high"), activeAlerts: 0),
        DeviceSummaryDTO(deviceId: "dev_charger", name: "USB-C Charger", present: true,
            firstSeen: "2026-08-25T09:13:00Z", lastSeen: "2026-08-25T09:13:00Z",
            vidPid: "1a2b:0001", serial: nil, interfaceClasses: ["hid_keyboard"],
            trust: "flagged", score: .init(value: 78, confidence: "medium"), activeAlerts: 1),
        DeviceSummaryDTO(deviceId: "dev_webcam", name: "HD Webcam", present: false,
            firstSeen: "2026-08-19T10:00:00Z", lastSeen: "2026-08-24T18:00:00Z",
            vidPid: "1bcf:2c99", serial: "C4D5", interfaceClasses: ["video"],
            trust: "none", score: nil, activeAlerts: 0),
    ], nextCursor: nil)

    public static let devicesEmpty = DeviceListDTO(devices: [], nextCursor: nil)

    /// 20 present devices + a few historical — conference-dock scale (7b).
    public static let devicesAtScale: DeviceListDTO = {
        var list: [DeviceSummaryDTO] = []
        let vendors = ["Logitech", "SanDisk", "Kingston", "Anker", "Dell", "Apple", "Samsung",
                       "Corsair", "Razer", "Belkin", "Elgato", "Keychron", "Seagate", "WD",
                       "Sony", "Bose", "Yubico", "Wacom", "Brother", "Epson"]
        let classes: [[String]] = [["hid_keyboard"], ["hid_mouse"], ["mass_storage"],
                                    ["hid_keyboard", "hid_mouse"], ["video"], ["audio"]]
        for i in 0..<20 {
            let scoreVal = [4, 12, 55, 78, 30, 8][i % 6]
            list.append(DeviceSummaryDTO(
                deviceId: "dev_\(i)",
                name: "\(vendors[i]) Device \(i)",
                present: true,
                firstSeen: "2026-08-25T0\(i % 9):00:00Z",
                lastSeen: "2026-08-25T09:\(String(format: "%02d", 59 - i))Z",
                vidPid: String(format: "%04x:%04x", 0x1000 + i, 0x2000 + i),
                serial: i % 3 == 0 ? "SER\(i)XYZ" : nil,
                interfaceClasses: classes[i % classes.count],
                trust: ["none", "trusted", "none", "flagged", "muted", "none"][i % 6],
                score: i % 2 == 0 ? .init(value: scoreVal, confidence: "medium") : nil,
                activeAlerts: i % 7 == 3 ? 1 : 0))
        }
        // A few historical (absent) rows below the fold.
        for i in 20..<24 {
            list.append(DeviceSummaryDTO(
                deviceId: "dev_\(i)", name: "Old Device \(i)", present: false,
                firstSeen: "2026-08-10T00:00:00Z", lastSeen: "2026-08-18T00:00:00Z",
                vidPid: String(format: "%04x:%04x", 0x3000 + i, 0x4000 + i),
                serial: nil, interfaceClasses: ["mass_storage"], trust: "none",
                score: nil, activeAlerts: 0))
        }
        return DeviceListDTO(devices: list, nextCursor: nil)
    }()

    // MARK: - device detail

    public static let deviceKeyboard = DeviceDetailDTO(
        deviceId: "dev_charger", name: "USB-C Charger", present: true,
        firstSeen: "2026-08-25T09:13:00Z", lastSeen: "2026-08-25T09:13:00Z",
        vidPid: "1a2b:0001", serial: nil, trust: "flagged",
        interfaces: [
            .init(seq: 0, usbClass: 3, subclass: 1, proto: 1, role: "keyboard"),
        ],
        topology: TopologyDTO(port: "20-2.4", hubPath: ["2", "4"]),
        trustHistory: [
            .init(tier: "flagged", actor: "you", at: "2026-08-25T09:14:30Z", note: "looked wrong"),
        ],
        isStorage: false
    )

    public static let deviceStorageAbsent = DeviceDetailDTO(
        deviceId: "dev_webcam", name: "HD Webcam", present: false,
        firstSeen: "2026-08-19T10:00:00Z", lastSeen: "2026-08-24T18:00:00Z",
        vidPid: "1bcf:2c99", serial: "C4D5", trust: "none",
        interfaces: [.init(seq: 0, usbClass: 14, subclass: 1, proto: 0, role: "camera")],
        topology: nil,
        trustHistory: [], isStorage: false
    )

    // MARK: - timeline

    public static let timelineNormal = TimelineDTO(events: [
        EventDTO(eventId: "evt_5", at: "2026-08-25T09:14:02Z", kind: "hid.typing_burst",
            severity: "warning", deviceId: "dev_charger",
            summary: "Started typing 0.4 seconds after it was plugged in. Human typists need a few seconds.",
            actor: "system"),
        EventDTO(eventId: "evt_4", at: "2026-08-25T09:13:40Z", kind: "device.mismatch",
            severity: "warning", deviceId: "dev_charger",
            summary: "This “USB-C Charger” also registered as a keyboard.", actor: "system"),
        EventDTO(eventId: "evt_3", at: "2026-08-25T09:13:00Z", kind: "device.attached",
            severity: "info", deviceId: "dev_charger",
            summary: "USB-C Charger plugged in.", actor: "system"),
        EventDTO(eventId: "evt_2", at: "2026-08-25T09:10:10Z", kind: "scan.clean",
            severity: "info", deviceId: "dev_sandisk",
            summary: "SanDisk Ultra scanned clean.", actor: "system"),
        EventDTO(eventId: "evt_1", at: "2026-08-25T09:10:00Z", kind: "device.attached",
            severity: "info", deviceId: "dev_sandisk",
            summary: "SanDisk Ultra plugged in.", actor: "system"),
    ], nextCursor: nil)

    public static let timelineEmpty = TimelineDTO(events: [], nextCursor: nil)

    /// A few hundred events with a monitoring gap row (7a), in plain language.
    /// The morning-after events sit above the gap so the "Monitoring was off…"
    /// row is visible near the top; the previous evening's events fall below it.
    public static let timelineAtScale: TimelineDTO = {
        // kind, plain summary, severity
        func summary(_ kind: String, _ n: Int) -> (String, String) {
            switch kind {
            case "device.attached": return ("A USB device plugged in.", "info")
            case "device.detached": return ("A USB device was unplugged.", "info")
            case "scan.clean": return ("A drive finished scanning: clean.", "info")
            case "hid.typing_burst": return ("A device started typing right after plug-in.", "warning")
            case "device.mismatch": return ("A device claimed one role but acted as another.", "notice")
            default: return ("Something happened.", "info")
            }
        }
        let kinds = ["device.attached", "device.detached", "scan.clean", "hid.typing_burst", "device.mismatch"]
        var events: [EventDTO] = []

        // Morning-after (after monitoring resumed at 08:03): 6 events, 08:05–09:59.
        let morning = ["09:59", "09:31", "09:02", "08:44", "08:20", "08:05"]
        for (i, t) in morning.enumerated() {
            let (s, sev) = summary(kinds[i % kinds.count], i)
            events.append(EventDTO(eventId: "evt_m\(i)", at: "2026-08-25T\(t):00Z",
                kind: kinds[i % kinds.count], severity: sev, deviceId: "dev_\(i % 20)",
                summary: s, actor: "system"))
        }

        // The monitoring gap is a `monitoring.gap` EVENT in the list (06), not a
        // separate field — rendered as an inline gap row. It sits at the moment
        // monitoring resumed so the row shows near the top (7a).
        events.append(EventDTO(eventId: "evt_gap1", at: "2026-08-25T08:03:00Z",
            kind: "monitoring.gap", severity: "notice", deviceId: nil,
            summary: "Monitoring was off between 02:14 and 08:03.", actor: "system"))

        // Previous evening (before the 02:14 gap start): a few hundred events.
        for i in 0..<300 {
            let hh = 23 - (i / 20) % 22   // 23:xx down toward 02:xx
            let mm = 59 - (i % 60)
            let day = hh >= 3 ? 24 : 25
            let k = kinds[i % kinds.count]
            let (s, sev) = summary(k, i)
            events.append(EventDTO(eventId: "evt_\(300 - i)",
                at: String(format: "2026-08-%02dT%02d:%02d:00Z", day, max(hh, 0), mm),
                kind: k, severity: sev, deviceId: "dev_\(i % 20)", summary: s, actor: "system"))
        }
        return TimelineDTO(events: events, nextCursor: "next_page")
    }()

    // MARK: - explanation

    public static let explanation = EventExplanationDTO(
        event: timelineNormal.events[0],
        why: "The first keystroke arrived 0.4 s after enumeration and the timing between keys was "
            + "unnaturally regular (mean 21 ms, deviation 3 ms). Both look automated.",
        suggestedActions: [
            .init(tool: "flag_device", label: "Flag this device"),
            .init(tool: "acknowledge_alert", label: "Acknowledge"),
        ])

    // MARK: - score

    public static let scoreElevated = ScoreDTO(
        score: 78, confidence: "medium",
        signals: [
            .init(id: "plug_to_type_latency", observed: "410ms", verdict: "suspicious", weight: 0.35),
            .init(id: "inter_key_timing", observed: "mean 21ms, stddev 3ms", verdict: "suspicious", weight: 0.35),
            .init(id: "redundant_keyboard", observed: "second keyboard, built-in present", verdict: "suspicious", weight: 0.15),
            .init(id: "class_mismatch", observed: "none", verdict: "clear", weight: 0.15),
        ],
        explanation: "This device began typing almost immediately and with machine-like regularity.",
        caveat: BehaviorVocabulary.caveat, sensorAvailable: true)

    /// Sensor off (Input Monitoring not granted): NO number (4b, null-not-zero).
    public static let scoreSensorOff = ScoreDTO(
        score: nil, confidence: nil, signals: [], explanation: nil,
        caveat: BehaviorVocabulary.caveat, sensorAvailable: false)

    /// Sensor on, but this device never typed: NO number (4b).
    public static let scoreNoData = ScoreDTO(
        score: nil, confidence: nil, signals: [], explanation: nil,
        caveat: BehaviorVocabulary.caveat, sensorAvailable: true)

    // MARK: - alerts

    public static let alertsOne = AlertListDTO(alerts: [
        AlertDTO(alertId: "alt_1", state: "active", severity: "warning",
            deviceId: "dev_charger", deviceName: "USB-C Charger",
            summary: "A “USB-C Charger” is acting like a keyboard.",
            why: "It claimed to be a charger but enumerated a keyboard and began typing 0.4 s later.",
            at: "2026-08-25T09:14:02Z",
            suggestedActions: [
                .init(tool: "acknowledge_alert", label: "Acknowledge"),
                .init(tool: "flag_device", label: "Flag device"),
            ]),
    ], nextCursor: nil)

    public static let alertsEmpty = AlertListDTO(alerts: [], nextCursor: nil)

    /// Five active alerts — the popover caps at three + "and 2 more" (04).
    public static let alertsMany = AlertListDTO(alerts: (0..<5).map { i in
        AlertDTO(alertId: "alt_\(i)", state: "active",
            severity: ["warning", "critical", "warning", "notice", "critical"][i],
            deviceId: "dev_\(i)", deviceName: "Device \(i)",
            summary: "Device \(i) did something worth a look.",
            why: "Because reasons \(i).", at: "2026-08-25T09:1\(i):00Z",
            suggestedActions: [.init(tool: "acknowledge_alert", label: "Acknowledge")])
    }, nextCursor: nil)

    public static let alertAcknowledged = AlertDTO(
        alertId: "alt_1", state: "acknowledged", severity: "warning",
        deviceId: "dev_charger", deviceName: "USB-C Charger",
        summary: "A “USB-C Charger” is acting like a keyboard.",
        why: "It claimed to be a charger but enumerated a keyboard.",
        at: "2026-08-25T09:14:02Z", suggestedActions: [])

    // MARK: - scans

    /// scan.start result (03: {scanId, state:"running"}).
    public static let scanStarted = ScanStartedDTO(scanId: "scn_2", state: .running)

    /// scans.list returns SUMMARIES (03/04) — the default the inspector reads.
    public static let scansClean = ScanListDTO(scans: [
        ScanSummaryDTO(scanId: "scn_1", deviceId: "dev_sandisk", state: .clean,
            engine: "clamdscan", startedAt: "2026-08-25T09:10:05Z",
            finishedAt: "2026-08-25T09:10:45Z", filesScanned: 128),
    ])

    public static let scanRunning = ScanDTO(
        scanId: "scn_2", deviceId: "dev_sandisk", volumePath: "/Volumes/ULTRA",
        state: .running, engine: "clamdscan", progress: 0.42,
        startedAt: "2026-08-25T09:15:00Z", verdicts: [], quarantine: [], reason: nil)

    public static let scanCanceled = ScanDTO(
        scanId: "scn_2", deviceId: "dev_sandisk", volumePath: "/Volumes/ULTRA",
        state: .canceled, engine: "clamdscan", progress: nil,
        startedAt: "2026-08-25T09:15:00Z", verdicts: [], quarantine: [],
        reason: "Canceled by you at 42%.")

    public static let scanInfected = ScanDTO(
        scanId: "scn_3", deviceId: "dev_sandisk", volumePath: "/Volumes/ULTRA",
        state: .infected, engine: "clamdscan", progress: nil,
        startedAt: "2026-08-25T09:16:00Z",
        verdicts: [.init(filePath: "/Volumes/ULTRA/invoice.exe", verdict: "infected", signature: "Win.Trojan.Agent")],
        quarantine: [.init(quarantineId: "qtn_1", filePath: "/Volumes/ULTRA/invoice.exe",
            signature: "Win.Trojan.Agent", restored: false, containment: "quarantined")],
        reason: nil)

    public static let scanFailed = ScanDTO(
        scanId: "scn_4", deviceId: "dev_sandisk", volumePath: "/Volumes/ULTRA",
        state: .failed, engine: "clamdscan", progress: nil,
        startedAt: "2026-08-25T09:17:00Z", verdicts: [], quarantine: [],
        reason: "The scanner engine stopped responding.")

    public static let quarantineRestored = QuarantineRestoreResultDTO(
        quarantineId: "qtn_1", scanId: "scn_3", deviceId: "dev_sandisk",
        originalPath: "/Volumes/ULTRA/invoice.exe", signature: "Win.Trojan.Agent",
        state: "restored",
        risk: "You are restoring a file ClamAV flagged; only do this if you are certain it is a false positive.",
        event: EventDTO(eventId: "evt_restore1", at: "2026-08-25T09:25:00Z",
            kind: "quarantine.restored", severity: "notice", deviceId: "dev_sandisk",
            summary: "Restored 'invoice.exe' from quarantine (flagged Win.Trojan.Agent) — by you.",
            actor: "ui"))

    // MARK: - policy

    public static let policyDefault = PolicyDTO(
        scanOnMount: true, holdUntilScanned: false, notificationThreshold: "warning")
}
