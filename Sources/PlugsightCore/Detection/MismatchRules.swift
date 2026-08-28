// MismatchRules.swift
//
// The class-mismatch rules R1-R6 (05): deterministic checks over interface
// descriptors alone, run at enumeration time. A rule either matches or does
// not, and the finding quotes the facts. No IOKit — input is plain descriptor
// structs (interface triples + vendor/product strings) from the 02 seam.
//
// Rule interplay, decided here and locked by tests:
// - R1 subsumes R4: a storage/billboard/vendor-primary device that hides a
//   keyboard raises ONE critical (R1), not a critical plus a warning about
//   the same two interfaces.
// - R3 subsumes R2: keyboard+network is the named combo; the same network
//   interface does not also fire "hidden network".
// - "Primary presentation" is the class of the first interface in
//   configuration order (lowest seq) — what the device leads with is what
//   the user believes they plugged in.

import Foundation

/// Detection event severities, ordered. `info` is the allowlist-downgrade
/// level; `notice` feeds the score rather than alerting by itself.
public enum DetectionSeverity: String, Equatable, Sendable, Comparable {
    case info, notice, warning, critical

    private var rank: Int {
        switch self {
        case .info: return 0
        case .notice: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: DetectionSeverity, rhs: DetectionSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The 05 rule identifiers, plus the allowlist-downgrade marker.
public enum MismatchRule: String, Equatable, Sendable, CaseIterable {
    case r1HiddenKeyboard = "r1_hidden_keyboard"
    case r2HiddenNetwork = "r2_hidden_network"
    case r3KeyboardPlusNetwork = "r3_keyboard_plus_network"
    case r4KeyboardPlusStorage = "r4_keyboard_plus_storage"
    case r5LateInterface = "r5_late_interface"
    case r6DescriptorAnomaly = "r6_descriptor_anomaly"
    /// Not a rule: the marker on the info event emitted when an allowlist
    /// shape matched and R1-R4 were downgraded (05).
    case allowlisted
}

/// One matched rule, with the facts quoted in `detail`.
public struct MismatchFinding: Equatable, Sendable {
    public let rule: MismatchRule
    public let severity: DetectionSeverity
    /// Event kind for the store/API: "mismatch.<rule>", or
    /// "mismatch.allowlisted" when an allowlist shape downgraded the check.
    public let kind: String
    /// Set when the finding was downgraded by an allowlist hit; names the
    /// matched pattern ("composite device matching the security-key shape").
    public let allowlistedPattern: String?
    public let detail: String

    public init(rule: MismatchRule, severity: DetectionSeverity, kind: String,
                allowlistedPattern: String?, detail: String) {
        self.rule = rule
        self.severity = severity
        self.kind = kind
        self.allowlistedPattern = allowlistedPattern
        self.detail = detail
    }
}

/// Plain descriptor facts for one enumeration of one device. No IOKit types.
public struct MismatchInput: Equatable, Sendable {
    public let vid: Int
    public let pid: Int
    public let vendorName: String?
    public let productName: String?
    /// Interfaces in configuration order.
    public let interfaces: [InterfaceDescriptor]
    /// Interface count of this device's FIRST enumeration this session;
    /// nil when this is the first enumeration (R5).
    public let previousInterfaceCount: Int?
    /// The serial changed across attaches on otherwise identical descriptors (R6).
    public let serialChangedAcrossAttaches: Bool

    public init(
        vid: Int,
        pid: Int,
        vendorName: String?,
        productName: String?,
        interfaces: [InterfaceDescriptor],
        previousInterfaceCount: Int? = nil,
        serialChangedAcrossAttaches: Bool = false
    ) {
        self.vid = vid
        self.pid = pid
        self.vendorName = vendorName
        self.productName = productName
        self.interfaces = interfaces
        self.previousInterfaceCount = previousInterfaceCount
        self.serialChangedAcrossAttaches = serialChangedAcrossAttaches
    }
}

/// USB interface class vocabulary (05). Standard code points, not tuning.
enum USBInterfaceClass {
    static let audio = 0x01
    static let cdcControl = 0x02
    static let hid = 0x03
    static let massStorage = 0x08
    static let hub = 0x09
    static let cdcData = 0x0A
    static let ccid = 0x0B
    static let video = 0x0E
    static let billboard = 0x11
    static let miscellaneous = 0xEF
    static let wirelessController = 0xE0
    static let vendorSpecific = 0xFF

    /// CDC subclass ECM (Ethernet Networking Control Model).
    static let cdcSubclassECM = 0x06
    /// CDC subclass NCM (Network Control Model).
    static let cdcSubclassNCM = 0x0D
    /// HID boot protocol: keyboard.
    static let hidProtocolKeyboard = 0x01
    /// HID boot protocol: mouse.
    static let hidProtocolMouse = 0x02
}

/// Class predicates shared by the rules and the allowlist shapes.
enum InterfaceClassifier {
    static func isKeyboard(_ i: InterfaceDescriptor) -> Bool {
        i.usbClass == USBInterfaceClass.hid && i.usbProtocol == USBInterfaceClass.hidProtocolKeyboard
    }

    static func isMouse(_ i: InterfaceDescriptor) -> Bool {
        i.usbClass == USBInterfaceClass.hid && i.usbProtocol == USBInterfaceClass.hidProtocolMouse
    }

    static func isHID(_ i: InterfaceDescriptor) -> Bool {
        i.usbClass == USBInterfaceClass.hid
    }

    static func isStorage(_ i: InterfaceDescriptor) -> Bool {
        i.usbClass == USBInterfaceClass.massStorage
    }

    /// Network per 05: CDC with subclass ECM/NCM, RNDIS in its common
    /// encodings, or a CDC-data plane interface.
    static func isNetwork(_ i: InterfaceDescriptor) -> Bool {
        if i.usbClass == USBInterfaceClass.cdcControl {
            if i.usbSubclass == USBInterfaceClass.cdcSubclassECM { return true }
            if i.usbSubclass == USBInterfaceClass.cdcSubclassNCM { return true }
            // RNDIS as CDC: class 0x02, subclass 0x02 (ACM), protocol 0xFF.
            if i.usbSubclass == 0x02 && i.usbProtocol == 0xFF { return true }
        }
        // RNDIS as wireless controller: 0xE0/0x01/0x03.
        if i.usbClass == USBInterfaceClass.wirelessController
            && i.usbSubclass == 0x01 && i.usbProtocol == 0x03 { return true }
        // RNDIS as miscellaneous: 0xEF/0x04/0x01.
        if i.usbClass == USBInterfaceClass.miscellaneous
            && i.usbSubclass == 0x04 && i.usbProtocol == 0x01 { return true }
        // CDC data plane.
        if i.usbClass == USBInterfaceClass.cdcData { return true }
        return false
    }
}

/// The deterministic rule engine. Pure: descriptors in, findings out.
public enum MismatchRules {

    /// Evaluate one enumeration with the allowlist checked BEFORE R1-R4 (05).
    /// A shape hit downgrades the composite to a single `mismatch.allowlisted`
    /// info event naming the pattern; R5 and R6 are behavioral-history checks,
    /// not composite-shape checks, so they still run.
    public static func evaluate(_ input: MismatchInput, allowlist: Allowlist) -> [MismatchFinding] {
        guard let pattern = allowlist.match(input.interfaces) else {
            return evaluate(input)
        }
        var findings = [MismatchFinding(
            rule: .allowlisted, severity: .info,
            kind: "mismatch.allowlisted",
            allowlistedPattern: pattern.id,
            detail: "composite device matching the \(pattern.id) shape")]
        findings += historyFindings(input)
        return findings
    }

    /// Evaluate R1-R6 for one enumeration (no allowlist: full severity).
    public static func evaluate(_ input: MismatchInput) -> [MismatchFinding] {
        compositeFindings(input) + historyFindings(input)
    }

    /// R1-R4: composite-shape rules, gated by the allowlist.
    private static func compositeFindings(_ input: MismatchInput) -> [MismatchFinding] {
        var findings: [MismatchFinding] = []

        let interfaces = input.interfaces
        let hasKeyboard = interfaces.contains(where: InterfaceClassifier.isKeyboard)
        let hasStorage = interfaces.contains(where: InterfaceClassifier.isStorage)
        let hasNetwork = interfaces.contains(where: InterfaceClassifier.isNetwork)
        let primary = interfaces.min(by: { $0.seq < $1.seq })

        // R1 hidden keyboard: storage/billboard/vendor primary presentation
        // AND a HID keyboard interface. Critical.
        var r1Fired = false
        if let primary, hasKeyboard {
            let disguises: [Int: String] = [
                USBInterfaceClass.massStorage: "mass storage",
                USBInterfaceClass.billboard: "billboard",
                USBInterfaceClass.vendorSpecific: "vendor-specific",
            ]
            if let presentation = disguises[primary.usbClass] {
                r1Fired = true
                findings.append(finding(.r1HiddenKeyboard, .critical,
                    "presented as \(presentation); also enumerated a keyboard interface"))
            }
        }

        // R3 keyboard plus network: critical. Named combo; subsumes R2.
        var r3Fired = false
        if hasKeyboard && hasNetwork {
            r3Fired = true
            findings.append(finding(.r3KeyboardPlusNetwork, .critical,
                "enumerated both a keyboard interface and a network interface"))
        }

        // R2 hidden network: a non-network-presenting device also enumerates
        // CDC ECM/NCM or RNDIS. Critical. Skipped when R3 already names it.
        if hasNetwork && !r3Fired, let primary, !InterfaceClassifier.isNetwork(primary) {
            findings.append(finding(.r2HiddenNetwork, .critical,
                "did not present as a network device; also enumerated a network interface"))
        }

        // R4 keyboard plus storage: warning. Skipped when R1 already covers
        // the same interfaces with a critical.
        if hasKeyboard && hasStorage && !r1Fired {
            findings.append(finding(.r4KeyboardPlusStorage, .warning,
                "enumerated both a keyboard interface and a mass storage interface"))
        }

        return findings
    }

    /// R5-R6: enumeration-history and descriptor-anomaly rules. Not gated by
    /// the allowlist — a legit shape whose serial mutates is still anomalous.
    private static func historyFindings(_ input: MismatchInput) -> [MismatchFinding] {
        var findings: [MismatchFinding] = []
        let interfaces = input.interfaces
        let hasKeyboard = interfaces.contains(where: InterfaceClassifier.isKeyboard)

        // R5 late interface: re-enumerated with MORE interfaces than the
        // first enumeration this session. Warning.
        if let previous = input.previousInterfaceCount, interfaces.count > previous {
            findings.append(finding(.r5LateInterface, .warning,
                "re-enumerated with \(interfaces.count) interfaces after first enumerating with \(previous)"))
        }

        // R6 descriptor anomaly: empty vendor AND product strings on a HID
        // keyboard device, or a serial change across attaches on otherwise
        // identical descriptors. Notice — feeds the score, never alerts alone.
        let vendorEmpty = (input.vendorName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let productEmpty = (input.productName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if hasKeyboard && vendorEmpty && productEmpty {
            findings.append(finding(.r6DescriptorAnomaly, .notice,
                "keyboard device with empty vendor and product strings"))
        } else if input.serialChangedAcrossAttaches {
            findings.append(finding(.r6DescriptorAnomaly, .notice,
                "serial number changed across attaches on otherwise identical descriptors"))
        }

        return findings
    }

    private static func finding(
        _ rule: MismatchRule, _ severity: DetectionSeverity, _ detail: String
    ) -> MismatchFinding {
        MismatchFinding(rule: rule, severity: severity,
                        kind: "mismatch.\(rule.rawValue)",
                        allowlistedPattern: nil, detail: detail)
    }
}
