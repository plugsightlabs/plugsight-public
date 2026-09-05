// DeviceInspectorViewModel.swift
//
// The device inspector pane (04): verdict first, decisions included. The canon
// pressure points: (1) the verdict headline leads — badge word + the safety
// reasons as plain sentences, each with its ONE working action; (2) the
// Behavior card honors null-not-zero — no number when the sensor is off or
// nothing was typed; (3) trust lives behind the "Alerts from this device"
// disclosure, `none` shown as Default, with consequence captions; (4) scan
// records expose Restore / Retry / Cancel exactly when valid, and a storage
// device with no scans says so instead of hiding the section.

import Foundation
import PlugsightCore

/// The Behavior card. A NUMBER exists in exactly one case — the honest one.
public enum BehaviorCardState: Equatable, Sendable {
    case score(value: Int, tierWord: String, signals: [ScoreSignalDTO], caveat: String)
    case sensorOff(message: String)   // Input Monitoring not granted (4b)
    case noData(message: String)      // sensor on, this device never typed
    case loading

    /// The data-honesty predicate: true iff a Behavior NUMBER is shown.
    public var showsNumber: Bool { if case .score = self { return true } else { return false } }
}

/// One safety reason, rendered: the plain sentence plus its ONE action.
public struct SafetyReasonVM: Equatable, Sendable, Identifiable {
    public var id: String
    public let sentence: String
    public let action: SafetyAction
    public init(id: String, sentence: String, action: SafetyAction) {
        self.id = id; self.sentence = sentence; self.action = action
    }
}

/// The verdict headline block: wire colour + reasons. The view derives the
/// verdict word/icon/tint from the shared PSSafetyBadge vocabulary.
public struct VerdictVM: Equatable, Sendable {
    public let status: String          // "green" | "yellow" | "red" | "grey"
    public let reasons: [SafetyReasonVM]
    public init(status: String, reasons: [SafetyReasonVM]) {
        self.status = status; self.reasons = reasons
    }
}

public struct InspectorHeader: Equatable, Sendable {
    public let name: String
    public let rolesText: String
    public let vidPid: String
    public let serial: String?
    public let present: Bool
    public let lastSeen: String
    public let isStorage: Bool
    /// Whether this device presents a keyboard/HID input face. The Behavior
    /// (typing) card renders ONLY for such devices; a camera or hub never shows
    /// "no typing observed" (an irrelevant field is noise, not honesty).
    public let hasInputFace: Bool
    /// The wire `lastSeen` formatted as local wall-clock text (shared formatter,
    /// timezone honesty) — what every renderer of this header shows.
    public var lastSeenDisplay: String { TimeFormatting.dateTime(lastSeen) }
    /// Absent devices state their status; trust stays active (6c).
    public var absentNote: String? { present ? nil : "Not connected, last seen \(lastSeenDisplay)." }
}

public struct ScanRecordVM: Equatable, Sendable, Identifiable {
    public var id: String { scanId }
    public let scanId: String
    public let state: ScanDTO.State
    public let progress: Double?
    public let reason: String?
    /// Wire timestamps (ISO-8601 UTC), kept raw for sorting/identity; the
    /// *Display strings below are what the UI renders.
    public let startedAt: String
    public let finishedAt: String?
    public var verdicts: [ScanVerdictDTO]
    public var quarantine: [QuarantineRecordDTO]
    public var showsCancel: Bool { state == .running }
    public var showsRetry: Bool { state == .failed }
    /// The plain state word (ScanVocabulary): "Malware found", never "infected".
    public var stateWord: String { ScanVocabulary.stateWord(state) }
    /// Local wall-clock presentation (shared formatter; never sliced ISO).
    public var startedAtDisplay: String { TimeFormatting.dateTime(startedAt) }
    public var finishedAtDisplay: String? { finishedAt.map { TimeFormatting.dateTime($0) } }
}

public struct TrustControlVM: Equatable, Sendable {
    public let current: TrustTier
    /// The four segments in display order; `none` labeled "Default".
    public let segments: [(tier: TrustTier, label: String, consequence: String)]
    /// One-time forgeability note on the user's first-ever trust action (6a).
    public var showForgeabilityNote: Bool

    public static func == (l: TrustControlVM, r: TrustControlVM) -> Bool {
        l.current == r.current && l.showForgeabilityNote == r.showForgeabilityNote
            && l.segments.map(\.tier) == r.segments.map(\.tier)
    }
}

public struct InspectorLoaded: Equatable, Sendable {
    public var header: InspectorHeader
    public var verdict: VerdictVM
    public var behavior: BehaviorCardState
    public var trust: TrustControlVM
    public var scans: [ScanRecordVM]
    /// This device's ACTIVE alerts (reviewAlerts renders them with Acknowledge).
    public var alerts: [AlertDTO]

    /// Restorable quarantine rows across this device's scans, newest scan
    /// first — what the reviewQuarantine reason reveals.
    public var quarantineRows: [QuarantineRecordDTO] {
        scans.flatMap(\.quarantine).filter { !$0.restored }
    }

    /// The newest clean scan on record — the "Scanned and safe" verdict card's
    /// substance (WHEN it was checked, not just that it was).
    public var lastCleanScan: ScanRecordVM? {
        scans.first { $0.state == .clean }
    }
}

public enum InspectorState: Equatable, Sendable {
    case loading
    case loaded(InspectorLoaded)
    case notFound(message: String)
    case storeError(message: String)
}

/// An undo toast raised after an immediate trust apply (04).
public struct UndoToast: Equatable, Sendable {
    public let message: String
    public let previousTier: TrustTier
}

@MainActor
public final class DeviceInspectorViewModel: ObservableObject {
    @Published public private(set) var state: InspectorState = .loading
    @Published public private(set) var undoToast: UndoToast?
    @Published public private(set) var trustWriteError: String?
    /// A failed verdict/scan/alert action surfaces here, inline (never destroys
    /// the pane) — the same shape as the trust-write error.
    @Published public private(set) var actionError: String?

    private let api: APIClient
    private let deviceId: String
    /// Whether the user has EVER set trust before (drives the first-use note).
    public var hasEverSetTrust: Bool

    public init(api: APIClient, deviceId: String, hasEverSetTrust: Bool = true) {
        self.api = api; self.deviceId = deviceId; self.hasEverSetTrust = hasEverSetTrust
    }
    public init(previewState: InspectorState) {
        self.api = FakeAPIClient(); self.deviceId = "preview"; self.hasEverSetTrust = true
        self.state = previewState
    }

    /// Map a score payload to the Behavior card, honoring null-not-zero.
    public static func behaviorCard(from s: ScoreDTO) -> BehaviorCardState {
        // Null-not-zero: a NUMBER exists only when the sensor is on AND the daemon
        // actually returned one (score != nil).
        if !s.sensorAvailable {
            return .sensorOff(message: "Typing observation is off (Input Monitoring not granted)")
        }
        guard let value = s.score else {
            return .noData(message: "No typing observed from this device")
        }
        return .score(value: value, tierWord: BehaviorVocabulary.tier(for: value).word,
                      signals: s.signals, caveat: s.caveat)
    }

    /// Map the wire safety status to the verdict block. A daemon that sends no
    /// verdict does NOT automatically read as "not checked": a device whose scan
    /// history holds a terminal result HAS been checked, so the verdict derives
    /// from the newest terminal scan (clean reads green, malware reads red).
    /// Only a device with no verdict AND no terminal scan reads grey — never
    /// invented safety, and never an invented "never checked" either.
    public static func verdict(from status: SafetyStatusDTO?,
                               scans: [ScanRecordVM] = []) -> VerdictVM {
        if let status {
            return VerdictVM(status: status.status, reasons: status.reasons.map {
                SafetyReasonVM(id: $0.id, sentence: $0.sentence, action: SafetyAction(wire: $0.action))
            })
        }
        if let last = scans.first(where: { $0.state == .clean || $0.state == .infected }) {
            return VerdictVM(status: last.state == .clean ? "green" : "red", reasons: [])
        }
        return VerdictVM(status: "grey", reasons: [])
    }

    /// The four trust segments, `none` labeled Default, in display order.
    private func trustControl(current: TrustTier, showNote: Bool) -> TrustControlVM {
        let segments = TrustVocabulary.displayOrder.map {
            (tier: $0, label: TrustVocabulary.label($0), consequence: TrustVocabulary.consequence($0))
        }
        return TrustControlVM(current: current, segments: segments, showForgeabilityNote: showNote)
    }

    private func header(from d: DeviceDetailDTO) -> InspectorHeader {
        // Dedupe repeated role words (e.g. two network interfaces must read
        // "network adapter" once, not twice), preserving order.
        var seen = Set<String>()
        let roles = d.interfaces.map { RoleNaming.plain($0.role) }
            .filter { seen.insert($0).inserted }
        let name = NamingVocabulary.displayName(rawName: d.name, roleHint: d.interfaces.first?.role)
        return InspectorHeader(name: name, rolesText: roles.joined(separator: ", "),
                               vidPid: d.vidPid,
                               serial: d.serial, present: d.present, lastSeen: d.lastSeen,
                               isStorage: d.isStorage,
                               hasInputFace: d.interfaces.contains { $0.role.contains("keyboard") })
    }

    public func load() async {
        do {
            let detail = try await api.getDevice(id: deviceId)
            // Score/scans/alerts are best-effort; a sensor-off score is a normal
            // state, not an error. Missing scans just render an empty list.
            let score = (try? await api.scoreDevice(id: deviceId)) ?? Canned.scoreNoData
            let scans = (try? await api.getScans(deviceId: deviceId))?.scans ?? []
            var scanVMs = scans.map {
                ScanRecordVM(scanId: $0.scanId, state: $0.state, progress: nil,
                             reason: $0.reason, startedAt: $0.startedAt,
                             finishedAt: $0.finishedAt, verdicts: [], quarantine: [])
            }
            // Enrich infected rows with their quarantine records (scan.get) so
            // the reviewQuarantine reason can list them with a working Restore.
            for (i, s) in scanVMs.enumerated() where s.state == .infected {
                if let full = try? await api.getScan(id: s.scanId) {
                    scanVMs[i].verdicts = full.verdicts
                    scanVMs[i].quarantine = full.quarantine
                }
            }
            let alerts = (try? await api.listAlerts(state: "active", deviceId: deviceId,
                                                    cursor: nil))?.alerts ?? []
            state = .loaded(InspectorLoaded(
                header: header(from: detail),
                verdict: Self.verdict(from: detail.safetyStatus, scans: scanVMs),
                behavior: Self.behaviorCard(from: score),
                trust: trustControl(current: TrustVocabulary.tier(fromWire: detail.trust),
                                    showNote: !hasEverSetTrust),
                scans: scanVMs,
                alerts: alerts))
        } catch let e as APIError {
            switch e.kind {
            case .notFound: state = .notFound(message: e.message)
            default: state = .storeError(message: e.message)
            }
        } catch {
            state = .storeError(message: "Can't read the device record")
        }
    }

    // MARK: - Verdict / scan / alert actions
    //
    // The one action pattern (04): async call, inline error string on failure
    // (input never destroyed), refresh after success so the surface shows the
    // daemon's new truth.

    /// Start (or retry) a scan of this device's storage.
    public func scanNow() async {
        await perform(fallback: "Couldn't start the scan.") {
            _ = try await self.api.scanStorage(deviceId: self.deviceId)
        }
    }

    /// Cancel a running scan.
    public func cancelScan(scanId: String) async {
        await perform(fallback: "Couldn't cancel the scan.") {
            _ = try await self.api.cancelScan(scanId: scanId)
        }
    }

    /// Restore one quarantined file. The confirm flag is always explicit: the
    /// view gathers the user's confirmation before calling this.
    public func restoreQuarantine(quarantineId: String) async {
        await perform(fallback: "Couldn't restore the file.") {
            _ = try await self.api.restoreQuarantine(quarantineId: quarantineId, confirm: true)
        }
    }

    /// Acknowledge one of this device's active alerts.
    public func acknowledgeAlert(alertId: String) async {
        await perform(fallback: "Couldn't acknowledge the alert.") {
            _ = try await self.api.acknowledgeAlert(alertId: alertId, comment: nil)
        }
    }

    public func dismissActionError() { actionError = nil }

    private func perform(fallback: String, _ op: () async throws -> Void) async {
        actionError = nil
        do {
            try await op()
            await load()
        } catch let e as APIError {
            actionError = e.message
        } catch {
            actionError = fallback
        }
    }

    /// Apply a trust tier immediately, raise the undo toast, keep value on failure.
    public func setTrust(_ tier: TrustTier) async {
        guard case .loaded(var loaded) = state else { return }
        let previous = loaded.trust.current
        let isFirst = !hasEverSetTrust
        trustWriteError = nil
        do {
            let updated = try await api.setTrust(deviceId: deviceId, tier: tier.rawValue, note: nil)
            hasEverSetTrust = true
            loaded.trust = trustControl(current: TrustVocabulary.tier(fromWire: updated.trust),
                                        showNote: isFirst)
            state = .loaded(loaded)
            undoToast = UndoToast(
                message: "Set to \(TrustVocabulary.label(tier)).",
                previousTier: previous)
        } catch let e as APIError {
            // A failed action never destroys input: value is preserved, reason inline.
            trustWriteError = e.message
        } catch {
            trustWriteError = "Couldn’t save the trust setting."
        }
    }

    /// Undo the last trust change by writing the previous tier back, then clear
    /// the toast. A failed undo surfaces inline like any other trust write.
    public func undoTrust() async {
        guard let toast = undoToast else { return }
        await setTrust(toast.previousTier)
        // A successful re-apply raised a fresh toast; the undo is complete, so
        // dismiss it. On failure `trustWriteError` is already set and the toast
        // is cleared here so the inline error is the single remaining signal.
        undoToast = nil
    }

    /// Dismiss the undo toast without changing trust (the toast auto-times-out in
    /// the live app; this is the explicit close).
    public func dismissUndo() { undoToast = nil }

    /// Clear a surfaced trust-write error once the user has seen it.
    public func dismissTrustWriteError() { trustWriteError = nil }
}
