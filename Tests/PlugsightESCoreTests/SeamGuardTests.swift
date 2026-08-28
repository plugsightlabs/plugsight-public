// SeamGuardTests.swift
//
// The N12 seam, self-enforced: PlugsightESCore is the PURE decision layer and
// must stay importable without the EndpointSecurity framework. ops/check-seam.sh
// guards PlugsightCore; this test guards PlugsightESCore the same way, from
// inside the suite, so a violation fails CI loudly.

import XCTest

final class SeamGuardTests: XCTestCase {

    func testESCoreSourcesNeverImportEndpointSecurityOrXPCFrameworks() throws {
        // Tests/PlugsightESCoreTests/SeamGuardTests.swift -> repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PlugsightESCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let esCore = repoRoot.appendingPathComponent("Sources/PlugsightESCore")
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: esCore, includingPropertiesForKeys: nil
        ))
        // Real import STATEMENTS only (line-anchored), so prose in comments
        // that merely mentions the framework does not trip the guard.
        let banned = #"(?m)^\s*(@\w+\s+)?import\s+(EndpointSecurity|XPC)\b"#
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(
                source.range(of: banned, options: [.regularExpression]),
                "SEAM VIOLATION: \(url.lastPathComponent) imports EndpointSecurity/XPC"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "found no ESCore sources — wrong path?")
    }
}
