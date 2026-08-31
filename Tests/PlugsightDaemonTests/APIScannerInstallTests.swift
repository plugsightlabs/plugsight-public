// APIScannerInstallTests.swift
//
// Wire-level tests for the scanner.install RPC and the additive status.get
// scanner fields (installState/installDetail/definitionsAgeDays). Everything is
// injected (brew locator, process runner, definitions age), so the suite never
// touches the network, real brew, or a real freshclam database. scanner.install
// is an app<->daemon RPC ONLY — it is intentionally NOT an MCP tool.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APIScannerInstallTests: XCTestCase {

    /// A scriptable install runner: returns queued results in order.
    private final class FakeRunner: InstallProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [InstallRunResult]
        init(results: [InstallRunResult]) { self.results = results }
        func run(executable: String, arguments: [String], environment: [String: String]) -> InstallRunResult {
            lock.lock(); defer { lock.unlock() }
            return results.isEmpty ? InstallRunResult(exitCode: 0, outputTail: "") : results.removeFirst()
        }
    }

    private func makeServer(
        installer: ScannerInstaller?,
        definitionsAge: (@Sendable () -> Int?)? = nil
    ) throws -> (APIServer, String) {
        let stateDir = makeTempStateDir()
        let db = try makeTestDB(inDir: stateDir)
        let server = try APIServer(
            databasePath: db.path,
            stateDirectory: stateDir,
            daemonVersion: "1.0.0",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: true, clamav: false),
            definitionsAgeResolver: definitionsAge,
            scannerInstaller: installer
        )
        return (server, stateDir)
    }

    func testScannerInstallRejectsWhenHomebrewMissing() throws {
        let installer = ScannerInstaller(
            brewLocator: { nil },
            runner: FakeRunner(results: []),
            homeDirectory: "/Users/test",
            runAsync: { _ in XCTFail("must not spawn when brew missing") })
        let (server, stateDir) = try makeServer(installer: installer)
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start(); defer { server.stop() }
        let c = try authedClient(server); defer { c.close() }

        // scanner.install with empty params -> accepted:false + homebrew reason.
        let resp = try XCTUnwrap(c.call(id: 1, method: "scanner.install").rpcResult)
        XCTAssertEqual(resp["accepted"] as? Bool, false)
        XCTAssertEqual(resp["reason"] as? String,
            "Homebrew was not found. Install Homebrew from brew.sh, or run the command in Terminal.")

        // status.get reflects the failed install state + detail.
        let status = try XCTUnwrap(c.call(id: 2, method: "status.get").rpcResult)
        let scanner = try XCTUnwrap(status["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["installState"] as? String, "failed")
        XCTAssertEqual(scanner["installDetail"] as? String,
            "Homebrew was not found. Install Homebrew from brew.sh, or run the command in Terminal.")
    }

    func testScannerInstallAcceptedAndReachesDone() throws {
        // Synchronous dispatch + a runner that succeeds twice -> by the time the
        // RPC returns the install is done; status.get shows it.
        let installer = ScannerInstaller(
            brewLocator: { "/opt/homebrew/bin/brew" },
            runner: FakeRunner(results: [
                InstallRunResult(exitCode: 0, outputTail: "installed"),
                InstallRunResult(exitCode: 0, outputTail: "updated"),
            ]),
            homeDirectory: "/Users/test",
            runAsync: { work in work() })
        let (server, stateDir) = try makeServer(installer: installer)
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start(); defer { server.stop() }
        let c = try authedClient(server); defer { c.close() }

        let resp = try XCTUnwrap(c.call(id: 1, method: "scanner.install").rpcResult)
        XCTAssertEqual(resp["accepted"] as? Bool, true)
        XCTAssertNil(resp["reason"] ?? nil)

        let status = try XCTUnwrap(c.call(id: 2, method: "status.get").rpcResult)
        let scanner = try XCTUnwrap(status["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["installState"] as? String, "done")
    }

    func testScannerInstallReportsNonZeroExitAsFailed() throws {
        let installer = ScannerInstaller(
            brewLocator: { "/opt/homebrew/bin/brew" },
            runner: FakeRunner(results: [
                InstallRunResult(exitCode: 1, outputTail: "Error: download failed"),
            ]),
            homeDirectory: "/Users/test",
            runAsync: { work in work() })
        let (server, stateDir) = try makeServer(installer: installer)
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start(); defer { server.stop() }
        let c = try authedClient(server); defer { c.close() }

        XCTAssertEqual(try XCTUnwrap(c.call(id: 1, method: "scanner.install").rpcResult)["accepted"] as? Bool, true)
        let status = try XCTUnwrap(c.call(id: 2, method: "status.get").rpcResult)
        let scanner = try XCTUnwrap(status["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["installState"] as? String, "failed")
        XCTAssertTrue((scanner["installDetail"] as? String)?.contains("download failed") == true)
    }

    func testStatusReportsRealDefinitionsAge() throws {
        let (server, stateDir) = try makeServer(installer: nil, definitionsAge: { 5 })
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start(); defer { server.stop() }
        let c = try authedClient(server); defer { c.close() }

        let status = try XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)
        let scanner = try XCTUnwrap(status["scanner"] as? [String: Any])
        XCTAssertEqual(scanner["definitionsAgeDays"] as? Int, 5)
        // With no installer wired the state is idle and detail absent/null.
        XCTAssertEqual(scanner["installState"] as? String, "idle")
    }

    func testStatusDefinitionsAgeNilWhenNoDatabase() throws {
        let (server, stateDir) = try makeServer(installer: nil, definitionsAge: { nil })
        defer { try? FileManager.default.removeItem(atPath: stateDir) }
        try server.start(); defer { server.stop() }
        let c = try authedClient(server); defer { c.close() }

        let status = try XCTUnwrap(c.call(id: 1, method: "status.get").rpcResult)
        let scanner = try XCTUnwrap(status["scanner"] as? [String: Any])
        XCTAssertNil(scanner["definitionsAgeDays"] ?? nil)
    }
}
