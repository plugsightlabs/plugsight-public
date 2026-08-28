// RoleNaming.swift
//
// Turns interface-class wire tokens (06) into the plain-language role words the
// UI shows. Jargon like "hid_keyboard" never reaches a screen; the human reads
// "keyboard". Unknown tokens fall back to a de-underscored best effort rather
// than raw taxonomy.

import Foundation

public enum RoleNaming {
    public static func plain(_ token: String) -> String {
        switch token {
        case "hid_keyboard", "keyboard": return "keyboard"
        case "hid_mouse", "mouse", "pointing": return "mouse"
        case "mass_storage", "storage": return "storage"
        case "video": return "camera"
        case "audio": return "audio device"
        case "hid_smartcard", "smartcard": return "smart card"
        case "hub": return "hub"
        case "printer": return "printer"
        case "network", "cdc": return "network adapter"
        default:
            return token.replacingOccurrences(of: "hid_", with: "")
                        .replacingOccurrences(of: "_", with: " ")
        }
    }
}
