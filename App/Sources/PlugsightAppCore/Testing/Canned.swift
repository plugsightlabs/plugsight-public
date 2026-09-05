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
        permissions: .init(inputMonitoring: true, inputMonitoringSensor: "active",
                           esExtension: .active),
        scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2,
                       installState: .done, installDetail: nil),
        devicesPresent: 4,
        activeAlerts: 1,
        monitoringGaps: []
    )

    /// Input Monitoring missing → typing-behavior scoring off (1b/4b).
    public static let statusDegraded = StatusDTO(
        monitoring: .degraded,
        daemonVersion: "1.0.0",
        permissions: .init(inputMonitoring: false, inputMonitoringSensor: "off",
                           esExtension: .active),
        scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2,
                       installState: .done, installDetail: nil),
        devicesPresent: 3,
        activeAlerts: 0,
        monitoringGaps: []
    )

    public static let statusStopped = StatusDTO(
        monitoring: .stopped,
        daemonVersion: "1.0.0",
        permissions: .init(inputMonitoring: true, inputMonitoringSensor: "active",
                           esExtension: .active),
        scanner: .init(available: true, engine: "clamdscan", definitionsAgeDays: 2,
                       installState: .done, installDetail: nil),
        devicesPresent: 0,
        activeAlerts: 0,
        monitoringGaps: [.init(from: "2026-08-25T02:14:00Z", to: "2026-08-25T08:03:00Z")]
    )

    /// Scanner absent + definitions age unknown → Settings scanner states (5c).
    public static let statusScannerMissing = StatusDTO(
        monitoring: .active,
        daemonVersion: "1.0.0",
        permissions: .init(inputMonitoring: true, inputMonitoringSensor: "active",
                           esExtension: .inactive),
        scanner: .init(available: false, engine: nil, definitionsAgeDays: nil,
                       installState: .idle, installDetail: nil),
        devicesPresent: 2,
        activeAlerts: 0,
        monitoringGaps: []
    )

    // MARK: - devices

    /// The yellow verdict the charger fixtures share (summary + detail agree).
    public static let safetyChargerYellow = SafetyStatusDTO(status: "yellow", reasons: [
        .init(id: "active_alert",
              sentence: "This device raised an alert that needs review.",
              action: "reviewAlerts"),
    ])

    public static let devicesNormal = DeviceListDTO(devices: [
        DeviceSummaryDTO(deviceId: "dev_sandisk", name: "SanDisk Ultra", present: true,
            firstSeen: "2026-08-25T09:10:00Z", lastSeen: "2026-08-25T09:14:00Z",
            vidPid: "0781:5581", serial: "AA010203", interfaceClasses: ["mass_storage"],
            trust: "none", score: nil, activeAlerts: 0, scanning: true,
            lastScan: .init(scanId: "scn_1", state: .clean, finishedAt: "2026-08-25T09:10:45Z"),
            safetyStatus: .init(status: "green", reasons: [])),
        DeviceSummaryDTO(deviceId: "dev_logi", name: "Logitech USB Receiver", present: true,
            firstSeen: "2026-08-20T08:00:00Z", lastSeen: "2026-08-25T09:00:00Z",
            vidPid: "046d:c52b", serial: nil, interfaceClasses: ["hid_keyboard", "hid_mouse"],
            trust: "trusted", score: .init(value: 4, confidence: "high"), activeAlerts: 0,
            safetyStatus: .init(status: "green", reasons: [])),
        DeviceSummaryDTO(deviceId: "dev_charger", name: "USB-C Charger", present: true,
            firstSeen: "2026-08-25T09:13:00Z", lastSeen: "2026-08-25T09:13:00Z",
            vidPid: "1a2b:0001", serial: nil, interfaceClasses: ["hid_keyboard"],
            trust: "flagged", score: .init(value: 78, confidence: "medium"), activeAlerts: 1,
            safetyStatus: safetyChargerYellow),
        DeviceSummaryDTO(deviceId: "dev_webcam", name: "HD Webcam", present: false,
            firstSeen: "2026-08-19T10:00:00Z", lastSeen: "2026-08-24T18:00:00Z",
            vidPid: "1bcf:2c99", serial: "C4D5", interfaceClasses: ["video"],
            trust: "none", score: nil, activeAlerts: 0),
    ], nextCursor: nil)

    public static let devicesEmpty = DeviceListDTO(devices: [], nextCursor: nil)

    /// 20 present devices + a few historical — conference-dock scale (7b).
    /// Names are REALISTIC product strings (what a descriptor actually says),
    /// never "Vendor Device N": the at-scale screenshots must show honest
    /// surfaces, and a judge (or the owner) must never see canned placeholders.
    public static let devicesAtScale: DeviceListDTO = {
        var list: [DeviceSummaryDTO] = []
        // One believable product name per row, matching classes[i % 6]:
        // 0 keyboard, 1 mouse, 2 storage, 3 keyboard+mouse, 4 video, 5 audio.
        let names = [
            "Logitech MX Keys",            // 0 keyboard
            "Logitech M720 Triathlon",     // 1 mouse
            "Kingston DataTraveler 3.0",   // 2 storage (the red malware row)
            "Anker 2.4G Wireless Receiver",// 3 keyboard+mouse combo
            "Dell UltraSharp Webcam",      // 4 video
            "Apple USB-C Audio Adapter",   // 5 audio
            "Corsair K70 RGB",             // 6 keyboard
            "Razer DeathAdder V3",         // 7 mouse
            "Samsung Portable SSD T7",     // 8 storage (failed scan row)
            "Logitech Unifying Receiver",  // 9 keyboard+mouse combo
            "Elgato Facecam",              // 10 video
            "Bose USB Link",               // 11 audio
            "Keychron K2",                 // 12 keyboard
            "Microsoft Sculpt Mouse",      // 13 mouse
            "Seagate Expansion Drive",     // 14 storage (failed scan row)
            "Dell Universal Receiver",     // 15 keyboard+mouse combo
            "Sony UVC Camera",             // 16 video
            "Focusrite Scarlett Solo",     // 17 audio
            "Das Keyboard 4",              // 18 keyboard
            "Wacom Intuos S",              // 19 pointing
        ]
        let classes: [[String]] = [["hid_keyboard"], ["hid_mouse"], ["mass_storage"],
                                    ["hid_keyboard", "hid_mouse"], ["video"], ["audio"]]
        for i in 0..<20 {
            let scoreVal = [4, 12, 55, 78, 30, 8][i % 6]
            // A believable verdict mix at scale: mostly green, a couple of
            // yellows, one red, a few greys (never-checked). The drive-shaped
            // reasons sit on the mass_storage rows (indices 2, 8, 14).
            let safety: SafetyStatusDTO?
            switch i {
            case 2: safety = SafetyStatusDTO(status: "red", reasons: [
                .init(id: "malware_found",
                      sentence: "The last scan found malware on this drive.",
                      action: "reviewQuarantine")])
            case 8, 14: safety = SafetyStatusDTO(status: "yellow", reasons: [
                .init(id: "scan_failed",
                      sentence: "The last scan did not finish.",
                      action: "scanAgain")])
            case 5, 11, 17: safety = nil  // grey: never checked
            default: safety = SafetyStatusDTO(status: "green", reasons: [])
            }
            list.append(DeviceSummaryDTO(
                deviceId: "dev_\(i)",
                name: names[i],
                present: true,
                firstSeen: "2026-08-25T0\(i % 9):00:00Z",
                lastSeen: "2026-08-25T09:\(String(format: "%02d", 59 - i))Z",
                vidPid: String(format: "%04x:%04x", 0x1000 + i, 0x2000 + i),
                serial: i % 3 == 0 ? "SER\(i)XYZ" : nil,
                interfaceClasses: classes[i % classes.count],
                trust: ["none", "trusted", "none", "flagged", "muted", "none"][i % 6],
                score: i % 2 == 0 ? .init(value: scoreVal, confidence: "medium") : nil,
                activeAlerts: i % 7 == 3 ? 1 : 0,
                lastScan: classes[i % classes.count].contains("mass_storage")
                    ? .init(scanId: "scn_at\(i)",
                            state: i == 2 ? .infected : (i == 8 || i == 14 ? .failed : .clean),
                            finishedAt: "2026-08-25T08:\(String(format: "%02d", 10 + i)):00Z")
                    : nil,
                safetyStatus: safety))
        }
        // A few historical (absent) rows below the fold.
        let historicalNames = ["SanDisk Ultra Fit", "PNY Attache 4",
                               "Toshiba Canvio Basics", "Verbatim Store 'n' Go"]
        for i in 20..<24 {
            list.append(DeviceSummaryDTO(
                deviceId: "dev_\(i)", name: historicalNames[i - 20], present: false,
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
        isStorage: false,
        safetyStatus: safetyChargerYellow
    )

    /// A storage device whose last scan found malware (S3a red path): the
    /// verdict carries a reviewQuarantine reason; the scan list carries the
    /// infected + failed + clean history the DetailUnsafe artboard shows.
    public static let deviceStorageInfected = DeviceDetailDTO(
        deviceId: "dev_sandisk", name: "SanDisk Ultra", present: true,
        firstSeen: "2026-08-25T09:10:00Z", lastSeen: "2026-08-25T09:14:00Z",
        vidPid: "0781:5581", serial: "AA010203", trust: "none",
        interfaces: [.init(seq: 0, usbClass: 8, subclass: 6, proto: 80, role: "storage")],
        topology: nil, trustHistory: [], isStorage: true,
        safetyStatus: SafetyStatusDTO(status: "red", reasons: [
            .init(id: "malware_found",
                  sentence: "The last scan found malware. 1 file was quarantined.",
                  action: "reviewQuarantine"),
        ])
    )

    /// A storage device scanned clean (S4 green path, DetailSafe artboard).
    public static let deviceStorageClean = DeviceDetailDTO(
        deviceId: "dev_kingston", name: "Kingston DataTraveler", present: true,
        firstSeen: "2026-08-25T09:10:00Z", lastSeen: "2026-08-25T09:14:00Z",
        vidPid: "0951:1666", serial: "KD1234", trust: "none",
        interfaces: [.init(seq: 0, usbClass: 8, subclass: 6, proto: 80, role: "storage")],
        topology: nil, trustHistory: [], isStorage: true,
        safetyStatus: SafetyStatusDTO(status: "green", reasons: [])
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

    /// The reference "now" the snapshot generator pins the timeline day-header
    /// humanizer to. The canned events live on 2026-08-25 (and the evening of
    /// -24 at scale), so pinning now to 2026-08-25 renders a stable "Today" /
    /// "Yesterday" instead of reading the live clock — which would make the
    /// timeline PNG fixtures render different bytes on every regeneration date.
    /// Snapshot rendering must stay reproducible; the humanizer's UTC clock is
    /// injected from here rather than defaulted to `Date()`.
    public static let timelineReferenceNow: Date = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 12))!
    }()

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
    /// Realistic names + plain summaries: these rows appear in the popover
    /// at-scale screenshots, so no "Device N" placeholders.
    public static let alertsMany = AlertListDTO(alerts: (0..<5).map { i in
        let names = ["Logitech MX Keys", "Kingston DataTraveler 3.0",
                     "Anker 2.4G Wireless Receiver", "Dell UltraSharp Webcam",
                     "Samsung Portable SSD T7"]
        let summaries = [
            "Logitech MX Keys started typing right after plug-in.",
            "Kingston DataTraveler 3.0 has a file the scanner flagged.",
            "Anker 2.4G Wireless Receiver registered a second keyboard.",
            "Dell UltraSharp Webcam claimed one role but acted as another.",
            "Samsung Portable SSD T7 has a file the scanner flagged.",
        ]
        return AlertDTO(alertId: "alt_\(i)", state: "active",
            severity: ["warning", "critical", "warning", "notice", "critical"][i],
            deviceId: "dev_\(i)", deviceName: names[i],
            summary: summaries[i],
            why: "The device's behavior did not match what it claimed to be.",
            at: "2026-08-25T09:1\(i):00Z",
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

    /// The infected-drive scan history (DetailUnsafe artboard): malware found,
    /// an earlier failed attempt with its reason, and an older clean pass.
    public static let scansInfectedHistory = ScanListDTO(scans: [
        ScanSummaryDTO(scanId: "scn_3", deviceId: "dev_sandisk", state: .infected,
            engine: "clamdscan", startedAt: "2026-08-25T10:11:00Z",
            finishedAt: "2026-08-25T10:12:00Z", filesScanned: 1204),
        ScanSummaryDTO(scanId: "scn_4", deviceId: "dev_sandisk", state: .failed,
            engine: "clamdscan", startedAt: "2026-08-25T09:56:00Z",
            finishedAt: "2026-08-25T09:56:20Z", filesScanned: 0,
            reason: "The drive could not be read."),
        ScanSummaryDTO(scanId: "scn_1", deviceId: "dev_sandisk", state: .clean,
            engine: "clamdscan", startedAt: "2026-08-24T18:40:00Z",
            finishedAt: "2026-08-24T18:41:00Z", filesScanned: 1187),
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
