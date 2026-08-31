// APIScannerFreshnessTests.swift
//
// Scanner availability must be FRESH on status.get, not the boot-time snapshot:
// a user who installs ClamAV while the daemon is running (the onboarding
// scanner step's whole flow) must see scanner.available flip without a daemon
// restart. The daemon injects a clamav resolver that re-runs engine discovery
// and returns the RESOLVED ENGINE NAME (nil = unavailable), so status.get
// reports the engine that actually resolved (clamdscan vs clamscan) instead of
// hardcoding one; these tests prove the router consults it per call, with no
// wire-shape change.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APIScannerFreshnessTests: XCTestCase {
    private final class EngineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeServer(capabilities: Capabilities, resolver: (@Sendable () -> String?)?)
        throws -> (APIServer, String) {
        let stateDir = makeTempStateDir()
        let db = try makeTestDB(inDir: stateDir)
        let server = try APIServer(
            databasePath: db.path,
            stateDirectory: stateDir,
            daemonVersion: "1.0.0",
            capabilities: capabilities,
            clamavResolver: resolver
        )
        return (server, stateDir)
    }

    func testStatusGetReflectsAFlippedClamavResolver() throws {
        let box = EngineBox()
        let (server, stateDir) = try makeServer(
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: false),
            resolver: { box.get() })
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start()
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }

        // Boot state: no scanner.
        var result = try XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)
        var scanner = try XCTUnwrap(result["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["available"] as? Bool, false)
        XCTAssertNil(scanner["engine"] ?? nil)
        XCTAssertEqual(result["monitoring"] as? String, "degraded")

        // ClamAV lands mid-run (brew install clamav, clamd up): the NEXT
        // status.get sees it and names the engine discovery resolved.
        box.set("clamdscan")
        result = try XCTUnwrap(c.call(id: 2, method: "status.get").rpcResult)
        scanner = try XCTUnwrap(result["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["available"] as? Bool, true)
        XCTAssertEqual(scanner["engine"] as? String, "clamdscan")
        XCTAssertEqual(result["monitoring"] as? String, "active",
                       "monitoring honesty follows the fresh value too")

        // And it flips back if the engine goes away.
        box.set(nil)
        result = try XCTUnwrap(c.call(id: 3, method: "status.get").rpcResult)
        scanner = try XCTUnwrap(result["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["available"] as? Bool, false)
        XCTAssertNil(scanner["engine"] ?? nil)
    }

    func testEngineReportsClamscanWhenThatIsWhatResolves() throws {
        // A host with clamscan on PATH but no running clamd must not be told
        // it is using clamdscan: status.get reports the engine discovery
        // actually resolved.
        let (server, stateDir) = try makeServer(
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: false),
            resolver: { "clamscan" })
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start()
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }

        let result = try XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)
        let scanner = try XCTUnwrap(result["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["available"] as? Bool, true)
        XCTAssertEqual(scanner["engine"] as? String, "clamscan")
    }

    func testShippedDaemonStaysDegradedWhileScannerFlips() throws {
        // What production actually exhibits: main.swift hardcodes
        // endpointSecurity=false in the shipped standalone daemon, so even
        // with Input Monitoring granted and ClamAV installed, monitoring is
        // "degraded" while scanner.available flips honestly.
        let box = EngineBox()
        let (server, stateDir) = try makeServer(
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: false),
            resolver: { box.get() })
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start()
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }

        var result = try XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)
        var scanner = try XCTUnwrap(result["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["available"] as? Bool, false)
        XCTAssertEqual(result["monitoring"] as? String, "degraded")

        box.set("clamdscan")
        result = try XCTUnwrap(c.call(id: 2, method: "status.get").rpcResult)
        scanner = try XCTUnwrap(result["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["available"] as? Bool, true)
        XCTAssertEqual(result["monitoring"] as? String, "degraded",
                       "the ES extension is still inactive; the mode must stay honest")
    }

    func testNoResolverKeepsBootCapabilityBehavior() throws {
        let (server, stateDir) = try makeServer(
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: true),
            resolver: nil)
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start()
        defer { server.stop() }
        let c = try authedClient(server)
        defer { c.close() }
        let result = try XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)
        let scanner = try XCTUnwrap(result["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["available"] as? Bool, true,
                       "without a resolver, the boot capability still answers (pure routing tests)")
    }
}
