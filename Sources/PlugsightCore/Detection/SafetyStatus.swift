// SafetyStatus.swift
//
// The derived per-device safety verdict (docs/spec/04, "The verdict model").
// Pure logic over facts the daemon already has: no storage of its own, no
// platform imports. Both faces (the app and @plugsight/mcp) receive the SAME
// derivation, so the row, the inspector, and the tool payload can never tell
// different stories.
//
// Rules (spec 04, binding):
//   red    — the last scan found malware, an active critical alert, or
//            behavior high. Red is reserved for real danger.
//   yellow — warning-grade conditions: scan failed, unacknowledged warning
//            alerts, elevated behavior, stale definitions weakening a clean
//            verdict.
//   green  — clean scan (storage) or no adverse signals (non-storage), no
//            active alerts, behavior quiet, and every applicable sensor on.
//   grey   — "not checked": never scanned, scanner missing, or the deciding
//            sensor off. Grey is never red; zero information never renders
//            as danger (Honesty Charter).
//
// Reasons are ordered most severe first; the status word is the worst
// applicable; each reason carries exactly ONE recommended action.

import Foundation

/// The four status words, ordered worst first for "worst applicable".
public enum SafetyStatusWord: String, Codable, Sendable, CaseIterable {
    case green, yellow, red, grey
}

/// The single recommended action a reason carries. The UI and MCP render these
/// as their one button/next step; `none` means "nothing to do, stay watching".
public enum SafetyAction: String, Codable, Sendable, CaseIterable {
    case scanAgain
    case installScanner
    case grantInputMonitoring
    case restartDaemon
    case reviewQuarantine
    case reviewAlerts
    case updateDefinitions
    case unplug
    case none
}

/// One plain-language reason inside a SafetyStatus: a stable id, a sentence
/// that says what happened and why, and exactly one recommended action.
public struct SafetyReason: Codable, Sendable, Equatable {
    public let id: String
    public let sentence: String
    public let action: SafetyAction

    public init(id: String, sentence: String, action: SafetyAction) {
        self.id = id
        self.sentence = sentence
        self.action = action
    }
}

/// Whether the typing-rhythm sensor is collecting (mirrors status.get's
/// `inputMonitoringSensor` wire words).
public enum TypingSensorState: String, Codable, Sendable {
    case active
    case restartRequired = "restart_required"
    case off
}

/// The facts one device's verdict is derived from. Everything here is already
/// known to the daemon per device; SafetyStatus adds no storage.
public struct SafetyInputs: Sendable, Equatable {
    /// The device enumerated a mass-storage interface (scans apply).
    public var isStorage: Bool
    /// The device enumerated a HID interface (the typing check applies).
    public var hasHIDInterface: Bool
    /// The most recent TERMINAL scan state for the device: "clean" |
    /// "infected" | "failed" | "skipped" | "canceled"; nil when never scanned.
    public var lastScanState: String?
    /// A scan of this device is in flight right now.
    public var scanning: Bool
    /// Active (unacknowledged) alert counts by severity.
    public var activeCriticalAlerts: Int
    public var activeWarningAlerts: Int
    /// The latest behavioral score; nil when nothing was observed (null-not-zero).
    public var behaviorScore: Int?
    public var behaviorConfidence: BehavioralScore.Confidence?
    /// Whether the typing-rhythm sensor is collecting.
    public var typingSensor: TypingSensorState
    /// A malware scanner is installed and resolvable right now.
    public var scannerAvailable: Bool
    /// Policy: scan drives when they mount (names the why on `scan.never`).
    public var scanOnMount: Bool
    /// Definitions age in whole days; nil when unknown (unknown is never stale).
    public var definitionsAgeDays: Int?
    public var definitionsWarnDays: Int

    public init(isStorage: Bool, hasHIDInterface: Bool,
                lastScanState: String?, scanning: Bool,
                activeCriticalAlerts: Int, activeWarningAlerts: Int,
                behaviorScore: Int?, behaviorConfidence: BehavioralScore.Confidence?,
                typingSensor: TypingSensorState,
                scannerAvailable: Bool, scanOnMount: Bool,
                definitionsAgeDays: Int?, definitionsWarnDays: Int) {
        self.isStorage = isStorage
        self.hasHIDInterface = hasHIDInterface
        self.lastScanState = lastScanState
        self.scanning = scanning
        self.activeCriticalAlerts = activeCriticalAlerts
        self.activeWarningAlerts = activeWarningAlerts
        self.behaviorScore = behaviorScore
        self.behaviorConfidence = behaviorConfidence
        self.typingSensor = typingSensor
        self.scannerAvailable = scannerAvailable
        self.scanOnMount = scanOnMount
        self.definitionsAgeDays = definitionsAgeDays
        self.definitionsWarnDays = definitionsWarnDays
    }
}

/// The derived verdict: one status word plus its reasons, most severe first.
public struct SafetyStatus: Codable, Sendable, Equatable {
    public let status: SafetyStatusWord
    public let reasons: [SafetyReason]

    public init(status: SafetyStatusWord, reasons: [SafetyReason]) {
        self.status = status
        self.reasons = reasons
    }

    /// Derive the verdict from one device's facts. Deterministic and total:
    /// every input combination yields a status and at least one reason.
    public static func derive(_ i: SafetyInputs, tuning: Tuning = .default) -> SafetyStatus {
        var red: [SafetyReason] = []
        var yellow: [SafetyReason] = []
        var grey: [SafetyReason] = []

        // ---- red: real danger only -------------------------------------
        if i.lastScanState == "infected" {
            red.append(SafetyReason(
                id: "scan.infected",
                sentence: "The last scan found malware on this device.",
                action: .reviewQuarantine))
        }
        if i.activeCriticalAlerts > 0 {
            red.append(SafetyReason(
                id: "alert.critical",
                sentence: alertSentence(count: i.activeCriticalAlerts, severityWord: "critical"),
                action: .reviewAlerts))
        }

        // ---- behavior: red when high with usable confidence, yellow when
        // elevated, and yellow AT MOST when confidence is low (a plausible
        // misattribution must never claim "Unsafe"; spec S5c).
        var behaviorYellow: SafetyReason?
        if let score = i.behaviorScore {
            let confidence = i.behaviorConfidence ?? .low
            if confidence == .low {
                if score >= tuning.warningScoreThreshold {
                    behaviorYellow = SafetyReason(
                        id: "behavior.uncertain",
                        sentence: "Typing looked unusual, but it may have been from another keyboard.",
                        action: .none)
                }
            } else if score >= tuning.criticalScoreThreshold {
                red.append(SafetyReason(
                    id: "behavior.high",
                    sentence: "Typing from this device looks automated.",
                    action: .unplug))
            } else if score >= tuning.warningScoreThreshold {
                behaviorYellow = SafetyReason(
                    id: "behavior.elevated",
                    sentence: "Typing from this device looks unusual.",
                    action: .unplug)
            }
        }

        // ---- yellow: warning-grade conditions ---------------------------
        if i.activeWarningAlerts > 0 {
            yellow.append(SafetyReason(
                id: "alert.warning",
                sentence: alertSentence(count: i.activeWarningAlerts, severityWord: "warning"),
                action: .reviewAlerts))
        }
        if let behaviorYellow { yellow.append(behaviorYellow) }
        if i.lastScanState == "failed" {
            yellow.append(SafetyReason(
                id: "scan.failed",
                sentence: "The last scan failed before it could finish.",
                action: .scanAgain))
        }
        // Stale definitions weaken a CLEAN verdict (an unchecked drive is
        // already grey; unknown age never claims staleness).
        if i.isStorage, i.scannerAvailable, i.lastScanState == "clean",
           let age = i.definitionsAgeDays, age > i.definitionsWarnDays {
            yellow.append(SafetyReason(
                id: "definitions.stale",
                sentence: "Virus definitions are out of date, so scans may miss new threats.",
                action: .updateDefinitions))
        }

        // ---- grey: unanswered questions (never danger) ------------------
        if i.isStorage {
            let hasVerdict = i.lastScanState == "clean" || i.lastScanState == "infected"
            if !i.scannerAvailable, !hasVerdict {
                grey.append(SafetyReason(
                    id: "scanner.missing",
                    sentence: "This drive could not be checked: no malware scanner is installed.",
                    action: .installScanner))
            }
            switch i.lastScanState {
            case nil where i.scanning:
                grey.append(SafetyReason(
                    id: "scan.running",
                    sentence: "A scan is running on this drive now.",
                    action: .none))
            case nil where i.scannerAvailable:
                grey.append(SafetyReason(
                    id: "scan.never",
                    sentence: i.scanOnMount
                        ? "This drive has not been scanned yet."
                        : "Not scanned yet: scanning new drives is turned off.",
                    action: .scanAgain))
            case "skipped":
                grey.append(SafetyReason(
                    id: "scan.skipped",
                    sentence: "The last scan was skipped, so this drive has not been checked.",
                    action: .scanAgain))
            case "canceled":
                grey.append(SafetyReason(
                    id: "scan.canceled",
                    sentence: "The last scan was canceled before it finished.",
                    action: .scanAgain))
            default:
                break
            }
        }
        if i.hasHIDInterface {
            switch i.typingSensor {
            case .off:
                grey.append(SafetyReason(
                    id: "sensor.off",
                    sentence: "Typing from this device cannot be checked: Input Monitoring is not granted.",
                    action: .grantInputMonitoring))
            case .restartRequired:
                grey.append(SafetyReason(
                    id: "sensor.restart",
                    sentence: "Typing cannot be checked yet: Plugsight needs a restart to start watching.",
                    action: .restartDaemon))
            case .active:
                break
            }
        }

        // ---- resolve: worst applicable word, reasons most severe first --
        let reasons = red + yellow + grey
        if !red.isEmpty { return SafetyStatus(status: .red, reasons: reasons) }
        if !yellow.isEmpty { return SafetyStatus(status: .yellow, reasons: reasons) }
        if !grey.isEmpty { return SafetyStatus(status: .grey, reasons: reasons) }
        return SafetyStatus(status: .green, reasons: [
            SafetyReason(
                id: "all.clear",
                sentence: i.isStorage
                    ? "The last scan found nothing and no alerts are active."
                    : "No alerts are active and nothing unusual has been observed.",
                action: .none),
        ])
    }

    private static func alertSentence(count: Int, severityWord: String) -> String {
        count == 1
            ? "A \(severityWord) alert on this device is waiting for review."
            : "\(count) \(severityWord) alerts on this device are waiting for review."
    }
}
