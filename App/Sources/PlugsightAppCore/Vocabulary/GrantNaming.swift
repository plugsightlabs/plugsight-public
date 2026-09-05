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
    ///
    /// `extensionBundled` is the honesty gate: a build that does not ship the
    /// .systemextension cannot have it granted by ANY user action, so blaming it
    /// in a footer or glyph would nag forever about something uninstallable. When
    /// the extension is not bundled, its absence is not a "missing grant" here;
    /// missing Input Monitoring or scanner still are. Defaults to true so callers
    /// that predate the gate (and a build that does ship it) keep the strict rule.
    public static func firstMissingGrant(_ status: StatusDTO,
                                         extensionBundled: Bool = true) -> String? {
        if !status.permissions.inputMonitoring { return "Input Monitoring" }
        if extensionBundled, status.permissions.esExtension != .active { return "the system extension" }
        if !status.scanner.available { return "the scanner" }
        return nil
    }
}
