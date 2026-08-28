// DevicesViewModel.swift
//
// The Devices section (04): inventory with judgement attached. Present devices
// lead, sorted by last activity; historical collapse below. A quiet behavior
// tier word appears only at notice+ (elevated/high) — an all-clear device shows
// no chip and no colour. A search field appears past 10 devices. Empty is
// deliberately action-free.

import Foundation

/// A rendered devices row. The chip word is nil for all-clear (data honesty:
/// no colour, no chip when nothing is wrong).
public struct DeviceRow: Equatable, Sendable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let name: String
    public let roles: [String]           // plain-language interface roles
    public let trustLabel: String        // "Default", never "none"
    public let behaviorChipWord: String? // nil = all-clear (no chip)
    public let present: Bool
    public let scanning: Bool
    public let activeAlerts: Int
    public init(deviceId: String, name: String, roles: [String], trustLabel: String,
                behaviorChipWord: String?, present: Bool, scanning: Bool, activeAlerts: Int) {
        self.deviceId = deviceId; self.name = name; self.roles = roles
        self.trustLabel = trustLabel; self.behaviorChipWord = behaviorChipWord
        self.present = present; self.scanning = scanning; self.activeAlerts = activeAlerts
    }
}

public struct DevicesLoaded: Equatable, Sendable {
    public var present: [DeviceRow]      // sorted by last activity, newest first
    public var historical: [DeviceRow]   // collapsed by default
    public var showsSearch: Bool         // appears at > 10 devices
    public var isEmpty: Bool             // no devices at all

    /// The exact empty sentence (04) — deliberately action-free.
    public var emptySentence: String? {
        isEmpty ? "Nothing has been plugged in since installation." : nil
    }
}

public enum DevicesState: Equatable, Sendable {
    case loading
    case loaded(DevicesLoaded)
    case storeError(message: String)
}

@MainActor
public final class DevicesViewModel: ObservableObject {
    @Published public private(set) var state: DevicesState = .loading
    private let api: APIClient

    public init(api: APIClient) { self.api = api }
    public init(previewState: DevicesState) { self.api = FakeAPIClient(); self.state = previewState }

    /// Map a device summary to a row, honoring the quiet-chip rule.
    public static func row(from d: DeviceSummaryDTO) -> DeviceRow {
        let roleHint = d.interfaceClasses.first
        let name = NamingVocabulary.displayName(rawName: d.name, roleHint: roleHint)
        let roles = d.interfaceClasses.map(RoleNaming.plain(_:))
        let trustLabel = TrustVocabulary.label(TrustVocabulary.tier(fromWire: d.trust))
        // Quiet-chip rule: only a tier word, only at notice+ (elevated/high),
        // never the number; all-clear shows nothing.
        let chip = d.score.flatMap { BehaviorVocabulary.rowChipWord(for: $0.value) }
        return DeviceRow(deviceId: d.deviceId, name: name, roles: roles,
                         trustLabel: trustLabel, behaviorChipWord: chip,
                         present: d.present, scanning: d.scanning ?? false,
                         activeAlerts: d.activeAlerts)
    }

    public func load() async {
        do {
            let list = try await api.listDevices(present: nil, trust: nil, cursor: nil)
            let rows = list.devices.map(Self.row(from:))
            // Present first, sorted by last activity (newest first). We keep the
            // source order's lastSeen by re-reading from the DTOs.
            let byId = Dictionary(uniqueKeysWithValues: list.devices.map { ($0.deviceId, $0.lastSeen) })
            let present = rows.filter { $0.present }
                .sorted { (byId[$0.deviceId] ?? "") > (byId[$1.deviceId] ?? "") }
            let historical = rows.filter { !$0.present }
                .sorted { (byId[$0.deviceId] ?? "") > (byId[$1.deviceId] ?? "") }
            state = .loaded(DevicesLoaded(
                present: present, historical: historical,
                showsSearch: list.devices.count > 10,
                isEmpty: list.devices.isEmpty))
        } catch let e as APIError {
            state = .storeError(message: e.message)
        } catch {
            state = .storeError(message: "Can't read the device record")
        }
    }
}
