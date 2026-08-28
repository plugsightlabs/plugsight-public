// GrantNaming.swift
//
// Degraded-mode copy names user-recognizable things only (04): "Input
// Monitoring", "the system extension", "the scanner". Internal names never
// reach a screen. This is the single place that turns a status permission gap
// into the plain-language grant name the footer/Settings show.

import Foundation

public enum GrantNaming {
    /// The first missing grant, in the order the onboarding walk presents them,
    /// or nil when everything needed is granted.
    public static func firstMissingGrant(_ status: StatusDTO) -> String? {
        if !status.permissions.inputMonitoring { return "Input Monitoring" }
        if status.permissions.esExtension != .active { return "the system extension" }
        if !status.scanner.available { return "the scanner" }
        return nil
    }
}
