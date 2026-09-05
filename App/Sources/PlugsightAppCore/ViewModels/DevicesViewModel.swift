// DevicesViewModel.swift
//
// The Devices home (04, Direction C "verdict header"): a machine-level verdict
// band, then a dense table answering "is everything safe" per device. Present
// devices lead, sorted by attention (red, yellow, grey, green) then last
// activity; historical collapse below. Rows carry the safety badge, the last
// scan cell, and the last check cell as PLAIN TEXT built here (never a raw
// enum or ISO string). A real search filters by name/roles past 10 devices.

import Foundation
import PlugsightCore

/// A rendered devices row. Every display string is built at mapping time so
/// the view renders text, never wire values.
public struct DeviceRow: Equatable, Sendable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let name: String
    public let roles: [String]           // plain-language interface roles
    public let trustLabel: String        // "Default", never "none"
    public let trustTier: TrustTier      // the ONE trust tint source (PS.trustTint)
    public let behaviorChipWord: String? // nil = all-clear (no chip)
    public let present: Bool
    public let scanning: Bool
    public let activeAlerts: Int
    /// The wire verdict colour ("green"|"yellow"|"red"|"grey"); grey when the
    /// daemon sent none. Drives PSSafetyBadge, never rendered raw.
    public let safetyStatus: String
    /// The first reason sentence (most severe), for the verdict band's detail.
    public let leadReason: String?
    /// The Last scan cell, ready to render: "Scanning…", "Today 9:14 AM",
    /// "Failed, Today 9:56 AM", "No scan", or "Not a drive".
    public let lastScanText: String
    /// The Last check cell answers WHEN: "Now" while present (the device is
    /// being checked right now), else the local last-seen time.
    public let lastCheckText: String
    /// Raw wire lastSeen, kept ONLY for sorting; never rendered.
    public let lastSeen: String

    public init(deviceId: String, name: String, roles: [String], trustLabel: String,
                trustTier: TrustTier, behaviorChipWord: String?, present: Bool,
                scanning: Bool, activeAlerts: Int, safetyStatus: String,
                leadReason: String?, lastScanText: String, lastCheckText: String,
                lastSeen: String) {
        self.deviceId = deviceId; self.name = name; self.roles = roles
        self.trustLabel = trustLabel; self.trustTier = trustTier
        self.behaviorChipWord = behaviorChipWord
        self.present = present; self.scanning = scanning; self.activeAlerts = activeAlerts
        self.safetyStatus = safetyStatus; self.leadReason = leadReason
        self.lastScanText = lastScanText; self.lastCheckText = lastCheckText
        self.lastSeen = lastSeen
    }
}

/// The machine-level verdict band (Direction C): one headline for the whole
/// fleet of CONNECTED devices, tinted by the worst present verdict.
public struct FleetVerdict: Equatable, Sendable {
    public let status: String    // "green" | "yellow" | "red" | "grey"
    public let headline: String
    public let detail: String?
    public init(status: String, headline: String, detail: String?) {
        self.status = status; self.headline = headline; self.detail = detail
    }
}

public struct DevicesLoaded: Equatable, Sendable {
    public var present: [DeviceRow]      // attention first, then last activity
    public var historical: [DeviceRow]   // collapsed by default
    public var showsSearch: Bool         // appears at > 10 devices
    public var isEmpty: Bool             // no devices at all
    /// The verdict band; nil only when there is nothing to judge.
    public var verdict: FleetVerdict?

    public init(present: [DeviceRow], historical: [DeviceRow], showsSearch: Bool,
                isEmpty: Bool, verdict: FleetVerdict? = nil) {
        self.present = present; self.historical = historical
        self.showsSearch = showsSearch; self.isEmpty = isEmpty; self.verdict = verdict
    }

    /// The exact empty sentence (04) — deliberately action-free.
    public var emptySentence: String? {
        isEmpty ? "Nothing has been plugged in since installation." : nil
    }

    /// Real search (04): filter rows by name or role, case-insensitively.
    /// The verdict band keeps judging the WHOLE fleet, not the filtered view.
    public func filtered(query: String) -> DevicesLoaded {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return self }
        func matches(_ r: DeviceRow) -> Bool {
            r.name.lowercased().contains(q)
                || r.roles.contains { $0.lowercased().contains(q) }
        }
        var copy = self
        copy.present = present.filter(matches)
        copy.historical = historical.filter(matches)
        return copy
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

    /// Map a device summary to a row: verdict, cells, and the quiet-chip rule.
    /// `now`/`timeZone` are injectable for deterministic renders and tests.
    public static func row(from d: DeviceSummaryDTO, now: Date = Date(),
                           timeZone: TimeZone = .current) -> DeviceRow {
        let roleHint = d.interfaceClasses.first
        let name = NamingVocabulary.displayName(rawName: d.name, roleHint: roleHint)
        // Dedupe repeated role words ("network adapter, network adapter" reads
        // once), preserving order.
        var seenRoles = Set<String>()
        let roles = d.interfaceClasses.map(RoleNaming.plain(_:))
            .filter { seenRoles.insert($0).inserted }
        let tier = TrustVocabulary.tier(fromWire: d.trust)
        // Quiet-chip rule: only a tier word, only at notice+ (elevated/high),
        // never the number; all-clear shows nothing.
        let chip = d.score.flatMap { BehaviorVocabulary.rowChipWord(for: $0.value) }
        let scanning = d.scanning ?? false
        let isStorage = d.interfaceClasses.contains { $0.contains("storage") }

        // The Last scan cell (04): live state wins, then the most recent scan's
        // outcome + local finish time, then the honest nothing-states.
        let lastScanText: String
        if scanning {
            lastScanText = "Scanning…"
        } else if let scan = d.lastScan {
            let time = scan.finishedAt.map {
                TimeFormatting.compact($0, now: now, timeZone: timeZone)
            }
            if scan.state == .clean {
                lastScanText = time ?? ScanVocabulary.stateWord(.clean)
            } else {
                let word = ScanVocabulary.stateWord(scan.state)
                lastScanText = time.map { "\(word), \($0)" } ?? word
            }
        } else {
            lastScanText = isStorage ? "No scan" : "Not a drive"
        }

        // A when-column answers with a time word, never a whether-word: present
        // devices are being checked "Now"; absent ones show the last-seen time.
        let lastCheckText = d.present
            ? "Now"
            : TimeFormatting.compact(d.lastSeen, now: now, timeZone: timeZone)

        return DeviceRow(deviceId: d.deviceId, name: name, roles: roles,
                         trustLabel: TrustVocabulary.label(tier), trustTier: tier,
                         behaviorChipWord: chip, present: d.present,
                         scanning: scanning, activeAlerts: d.activeAlerts,
                         safetyStatus: d.safetyStatus?.status ?? "grey",
                         leadReason: d.safetyStatus?.reasons.first?.sentence,
                         lastScanText: lastScanText, lastCheckText: lastCheckText,
                         lastSeen: d.lastSeen)
    }

    /// Attention rank for sorting: red leads, green trails.
    private static func attentionRank(_ status: String) -> Int {
        switch status {
        case "red": return 0
        case "yellow": return 1
        case "grey": return 2
        default: return 3  // green
        }
    }

    /// The machine-level verdict, derived from the CONNECTED devices' statuses.
    /// nil when nothing is connected (the band has nothing honest to say).
    public static func fleetVerdict(present: [DeviceRow]) -> FleetVerdict? {
        guard !present.isEmpty else { return nil }
        let red = present.filter { $0.safetyStatus == "red" }
        let yellow = present.filter { $0.safetyStatus == "yellow" }
        let green = present.filter { $0.safetyStatus == "green" }
        let grey = present.filter { $0.safetyStatus == "grey" }

        // The offending devices' names, with the single offender's reason.
        func lead(_ rows: [DeviceRow]) -> String {
            if rows.count == 1 {
                let name = rows[0].name
                if let reason = rows[0].leadReason {
                    return reason.hasSuffix(".") ? "\(name). \(reason)" : "\(name). \(reason)."
                }
                return "\(name)."
            }
            return rows.map(\.name).joined(separator: ", ") + "."
        }
        // Reassure about the rest only when the rest actually checked out green.
        func reassurance(offenders: Int) -> String? {
            guard offenders < present.count, grey.isEmpty else { return nil }
            return "Everything else connected looks safe."
        }

        if !red.isEmpty {
            let headline = red.count == 1
                ? "1 device is unsafe" : "\(red.count) devices are unsafe"
            var detail = lead(red)
            if !yellow.isEmpty {
                detail += yellow.count == 1
                    ? " 1 more device needs attention."
                    : " \(yellow.count) more devices need attention."
            } else if let r = reassurance(offenders: red.count) {
                detail += " " + r
            }
            return FleetVerdict(status: "red", headline: headline, detail: detail)
        }
        if !yellow.isEmpty {
            let headline = yellow.count == 1
                ? "1 device needs attention" : "\(yellow.count) devices need attention"
            var detail = lead(yellow)
            if let r = reassurance(offenders: yellow.count) { detail += " " + r }
            return FleetVerdict(status: "yellow", headline: headline, detail: detail)
        }
        if green.isEmpty {
            // Grey-only fleet: nothing has a verdict yet. Honest, not alarming.
            return FleetVerdict(status: "grey", headline: "Not checked yet",
                                detail: "Devices show a verdict after their first check.")
        }
        let detail = grey.isEmpty ? nil
            : (grey.count == 1 ? "1 device has not been checked yet."
                               : "\(grey.count) devices have not been checked yet.")
        return FleetVerdict(status: "green",
                            headline: "Everything connected looks safe",
                            detail: detail)
    }

    /// Sort rows by attention (red, yellow, grey, green), then last activity.
    static func sorted(_ rows: [DeviceRow]) -> [DeviceRow] {
        rows.sorted {
            let l = attentionRank($0.safetyStatus), r = attentionRank($1.safetyStatus)
            if l != r { return l < r }
            return $0.lastSeen > $1.lastSeen
        }
    }

    public func load(now: Date = Date(), timeZone: TimeZone = .current) async {
        do {
            let list = try await api.listDevices(present: nil, trust: nil, cursor: nil)
            let rows = list.devices.map { Self.row(from: $0, now: now, timeZone: timeZone) }
            let present = Self.sorted(rows.filter { $0.present })
            let historical = rows.filter { !$0.present }
                .sorted { $0.lastSeen > $1.lastSeen }
            state = .loaded(DevicesLoaded(
                present: present, historical: historical,
                showsSearch: list.devices.count > 10,
                isEmpty: list.devices.isEmpty,
                verdict: Self.fleetVerdict(present: present)))
        } catch let e as APIError {
            state = .storeError(message: e.message)
        } catch {
            state = .storeError(message: "Can't read the device record")
        }
    }
}
