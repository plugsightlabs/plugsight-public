// PlugsightIdentifiers.swift
//
// The canonical product identifiers, defined ONCE (docs/spec/02). Before this
// file existed the codebase had drifted three ways: the app and release.mjs
// used a longer "...esextension" spelling while the extension's Info.plist
// (plus spec 02) declared "com.plugsight.esext". The spec's id wins. Every
// Swift reference goes through these constants; the packaging scripts and
// plists are pinned to the same strings by IdentifierUnificationTests.

public enum PlugsightIdentifiers {
    /// The ES system extension's bundle id (docs/spec/02 identity table, and
    /// ESExtension/Info.plist CFBundleIdentifier). The appex directory inside
    /// the app bundle is "Contents/Library/SystemExtensions/\(id).systemextension".
    public static let esExtensionBundleID = "com.plugsight.esext"

    /// The XPC Mach service the extension publishes for the daemon (fixed in
    /// ESExtension/Info.plist under NSEndpointSecurityMachServiceName).
    public static let esExtensionMachServiceName = "com.plugsight.esext.xpc"

    /// The menu-bar app's bundle id (release.mjs / ops/dev-bundle.sh).
    public static let appBundleID = "com.plugsight.app"

    /// The Apple Developer team every Plugsight binary is signed under
    /// (docs/RELEASE-SIGNING.md). Both XPC peers pin this in their
    /// code-signing requirements.
    public static let teamID = "K4GPUAV422"

    /// The bundle-id prefix the XPC peer validation accepts (02).
    public static let bundleIDPrefix = "com.plugsight."

    /// The code-signing IDENTIFIER of the plugsightd binary — what the
    /// extension's exact-identifier requirement matches against. The
    /// packaging scripts (ops/dev-bundle.sh, ops/release.mjs) sign the daemon
    /// with an explicit `--identifier` set to this string, so the value never
    /// depends on codesign's filename inference.
    public static let daemonCodeSignIdentifier = "com.plugsight.daemon"
}
