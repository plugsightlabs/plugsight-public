// DeviceInspectorViewModel.swift
//
// The device inspector pane (04): the full dossier for one device. The canon
// pressure points here are (1) the Behavior card's null-not-zero rule — no number
// when the sensor is off or nothing was typed, the state sentence instead; (2)
// the trust control's four segments with `none` shown as Default and the first-
// ever forgeability note; (3) an absent device still carrying an active trust
// control; (4) scan records exposing Restore / Retry / Cancel exactly when valid.

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

public struct InspectorHeader: Equatable, Sendable {
    public let name: String
    public let rolesText: String
    public let vidPid: String
    public let serial: String?
    public let present: Bool
    public let lastSeen: String
    public let isStorage: Bool
    /// Storage devices carry Eject in the header (04); a standard OS op, GUI-only.
    public var showsEject: Bool { isStorage }
    /// Absent devices state their status; trust stays active (6c).
    public var absentNote: String? { present ? nil : "Not connected, last seen \(lastSeen)." }
}

public struct ScanRecordVM: Equatable, Sendable, Identifiable {
    public var id: String { scanId }
    public let scanId: String
    public let state: ScanDTO.State
    public let progress: Double?
    public let reason: String?
    public let verdicts: [ScanVerdictDTO]
    public let quarantine: [QuarantineRecordDTO]
    public var showsCancel: Bool { state == .running }
    public var showsRetry: Bool { state == .failed }
    /// Canceled never renders as clean (05/04): its own word + reason.
    public var stateWord: String { state.rawValue }
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
    public var behavior: BehaviorCardState
    public var trust: TrustControlVM
    public var scans: [ScanRecordVM]
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

    /// The four trust segments, `none` labeled Default, in display order.
    private func trustControl(current: TrustTier, showNote: Bool) -> TrustControlVM {
        let segments = TrustVocabulary.displayOrder.map {
            (tier: $0, label: TrustVocabulary.label($0), consequence: TrustVocabulary.consequence($0))
        }
        return TrustControlVM(current: current, segments: segments, showForgeabilityNote: showNote)
    }

    private func header(from d: DeviceDetailDTO) -> InspectorHeader {
        let rolesText = d.interfaces.map { RoleNaming.plain($0.role) }.joined(separator: ", ")
        let name = NamingVocabulary.displayName(rawName: d.name, roleHint: d.interfaces.first?.role)
        return InspectorHeader(name: name, rolesText: rolesText, vidPid: d.vidPid,
                               serial: d.serial, present: d.present, lastSeen: d.lastSeen,
                               isStorage: d.isStorage)
    }

    private func loadedFromDetail(_ d: DeviceDetailDTO, score: ScoreDTO, scans: [ScanSummaryDTO]) -> InspectorLoaded {
        // scans.list returns SUMMARIES (03/04): the record row shows the state (and
        // its state-based actions); full per-file verdicts/quarantine come from
        // scan.get on demand, so they start empty here.
        let scanVMs = scans.map {
            ScanRecordVM(scanId: $0.scanId, state: $0.state, progress: nil,
                         reason: nil, verdicts: [], quarantine: [])
        }
        return InspectorLoaded(
            header: header(from: d),
            behavior: Self.behaviorCard(from: score),
            trust: trustControl(current: TrustVocabulary.tier(fromWire: d.trust),
                                showNote: !hasEverSetTrust),
            scans: scanVMs)
    }

    public func load() async {
        do {
            let detail = try await api.getDevice(id: deviceId)
            // Score/scans are best-effort; a sensor-off score is a normal state,
            // not an error. Missing scans just render an empty list.
            let score = (try? await api.scoreDevice(id: deviceId)) ?? Canned.scoreNoData
            let scans = (try? await api.getScans(deviceId: deviceId))?.scans ?? []
            state = .loaded(loadedFromDetail(detail, score: score, scans: scans))
        } catch let e as APIError {
            switch e.kind {
            case .notFound: state = .notFound(message: e.message)
            default: state = .storeError(message: e.message)
            }
        } catch {
            state = .storeError(message: "Can't read the device record")
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
