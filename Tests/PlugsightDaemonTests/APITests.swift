// APITests.swift
//
// N4: the local API server (UDS, newline-framed JSON-RPC 2.0). These tests drive
// a REAL socket in a temp dir, exactly as the UI (N9) and MCP (N10) will.
//
// Unit A: framing + auth gate + on-disk mode bits.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

final class APITestsAuth: XCTestCase {
    private var server: APIServer!
    private var stateDir: String!

    override func setUpWithError() throws {
        stateDir = makeTempStateDir()
        let db = try makeTestDB(inDir: stateDir)
        server = try APIServer(
            databasePath: db.path,
            stateDirectory: stateDir,
            daemonVersion: "1.2.3",
            capabilities: Capabilities(inputMonitoring: true, endpointSecurity: false, clamav: true)
        )
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    private func token() throws -> String {
        let raw = try String(contentsOfFile: server.tokenPath, encoding: .utf8)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Framing + auth

    func testUnauthenticatedFirstMessageIsRejectedAndConnectionCloses() throws {
        let c = try UDSTestClient(socketPath: server.socketPath)
        defer { c.close() }
        try c.send(["jsonrpc": "2.0", "id": 1, "method": "status.get", "params": [:]])
        let resp = c.readLine()
        XCTAssertNotNil(resp, "expected an error response before close")
        let err = resp?.rpcError
        XCTAssertEqual(err?["code"] as? Int, -32001)
        XCTAssertEqual((err?["data"] as? [String: Any])?["kind"] as? String, "unauthorized")
        // The connection must then be CLOSED by the server.
        XCTAssertTrue(c.isClosedByPeer(), "server must close after an unauthorized first message")
    }

    func testBadTokenIsRejectedAndConnectionCloses() throws {
        let c = try UDSTestClient(socketPath: server.socketPath)
        defer { c.close() }
        try c.send([
            "jsonrpc": "2.0", "id": 1, "method": "auth.hello",
            "params": ["token": "not-the-real-token",
                       "clientInfo": ["name": "test", "kind": "cli"]]
        ])
        let resp = c.readLine()
        XCTAssertEqual(resp?.rpcError?["code"] as? Int, -32001)
        XCTAssertEqual((resp?.rpcError?["data"] as? [String: Any])?["kind"] as? String, "unauthorized")
        XCTAssertTrue(c.isClosedByPeer())
    }

    func testHelloReturnsApiVersionAndCapabilities() throws {
        let c = try UDSTestClient(socketPath: server.socketPath)
        defer { c.close() }
        try c.send([
            "jsonrpc": "2.0", "id": 7, "method": "auth.hello",
            "params": ["token": try token(),
                       "clientInfo": ["name": "claude-code", "kind": "mcp"]]
        ])
        let resp = try XCTUnwrap(c.readLine())
        XCTAssertEqual(resp["id"] as? Int, 7)
        let result = try XCTUnwrap(resp.rpcResult)
        XCTAssertEqual(result["apiVersion"] as? Int, 1)
        XCTAssertEqual(result["daemonVersion"] as? String, "1.2.3")
        let caps = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertEqual(caps["inputMonitoring"] as? Bool, true)
        XCTAssertEqual(caps["endpointSecurity"] as? Bool, false)
        XCTAssertEqual(caps["clamav"] as? Bool, true)
    }

    func testAuthenticatedConnectionStaysOpenForFurtherCalls() throws {
        let c = try UDSTestClient(socketPath: server.socketPath)
        defer { c.close() }
        try c.send([
            "jsonrpc": "2.0", "id": 1, "method": "auth.hello",
            "params": ["token": try token(),
                       "clientInfo": ["name": "ui", "kind": "ui"]]
        ])
        _ = try XCTUnwrap(c.readLine())
        // A second call on the same, now-authenticated, connection must succeed.
        try c.send(["jsonrpc": "2.0", "id": 2, "method": "status.get", "params": [:]])
        let resp = try XCTUnwrap(c.readLine())
        XCTAssertNil(resp.rpcError, "status.get after hello should not error")
        XCTAssertNotNil(resp.rpcResult)
    }

    func testDoubleHelloOnSameConnectionIsInvalidParams() throws {
        let c = try UDSTestClient(socketPath: server.socketPath)
        defer { c.close() }
        try c.send([
            "jsonrpc": "2.0", "id": 1, "method": "auth.hello",
            "params": ["token": try token(), "clientInfo": ["name": "ui", "kind": "ui"]]
        ])
        _ = try XCTUnwrap(c.readLine())
        try c.send([
            "jsonrpc": "2.0", "id": 2, "method": "auth.hello",
            "params": ["token": try token(), "clientInfo": ["name": "ui", "kind": "ui"]]
        ])
        let resp = try XCTUnwrap(c.readLine())
        XCTAssertNotNil(resp.rpcError, "a second auth.hello is not allowed")
    }

    // MARK: - On-disk protection

    func testSocketAndTokenAreMode0600() throws {
        let fm = FileManager.default
        let sockAttrs = try fm.attributesOfItem(atPath: server.socketPath)
        let tokenAttrs = try fm.attributesOfItem(atPath: server.tokenPath)
        let sockPerm = (sockAttrs[.posixPermissions] as? NSNumber)?.intValue
        let tokenPerm = (tokenAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(sockPerm, 0o600, "socket must be 0600")
        XCTAssertEqual(tokenPerm, 0o600, "token file must be 0600")
    }

    func testTokenFileIs32RandomBytesRendered() throws {
        // 32 bytes rendered as lowercase hex = 64 chars.
        let t = try token()
        XCTAssertEqual(t.count, 64)
        XCTAssertTrue(t.allSatisfy { $0.isHexDigit })
    }
}
