// IdentifierUnificationTests.swift
//
// Pins the ES extension identity to ONE set of strings (docs/spec/02). The
// codebase once drifted three ways (com.plugsight.esextension in the app,
// com.plugsight.esextension.systemextension in release.mjs,
// com.plugsight.esext in the extension's own Info.plist); these tests make any
// recurrence a loud, reviewed failure by checking the Swift constants against
// each other AND against the checked-in plist / packaging scripts.

import XCTest
import PlugsightCore
@testable import PlugsightESCore

final class IdentifierUnificationTests: XCTestCase {

    /// Repo root derived from this file's location (Tests/PlugsightESCoreTests/).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PlugsightESCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    func testMachServiceNameDerivesFromTheBundleID() {
        XCTAssertEqual(
            PlugsightIdentifiers.esExtensionMachServiceName,
            PlugsightIdentifiers.esExtensionBundleID + ".xpc"
        )
        XCTAssertEqual(ESDefaults.machServiceName, PlugsightIdentifiers.esExtensionMachServiceName)
    }

    func testExtensionInfoPlistDeclaresTheCanonicalIdentity() throws {
        let plistURL = repoRoot.appendingPathComponent("ESExtension/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String,
                       PlugsightIdentifiers.esExtensionBundleID)
        XCTAssertEqual(plist["NSEndpointSecurityMachServiceName"] as? String,
                       PlugsightIdentifiers.esExtensionMachServiceName)
    }

    /// The stale id must never reappear anywhere in the Swift sources or the
    /// packaging scripts. (The canonical id is a prefix of the stale one, so
    /// this greps for the stale FULL id specifically.)
    func testStaleBundleIDIsGoneFromSourcesAndOps() throws {
        let staleID = "com.plugsight." + "esextension"   // split so this file never matches itself
        let fm = FileManager.default
        var offenders: [String] = []
        for dir in ["Sources", "App/Sources", "ops"] {
            let base = repoRoot.appendingPathComponent(dir)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                guard ["swift", "mjs", "sh", "plist"].contains(url.pathExtension) else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains(staleID) {
                    offenders.append(url.path)
                }
            }
        }
        XCTAssertEqual(offenders, [], "stale ES extension bundle id found in: \(offenders)")
    }
}
