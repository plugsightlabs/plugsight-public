// APITestSupport.swift
//
// Shared helpers for the N4 API tests: a short-lived temp state directory (the
// UDS path must stay under the 104-byte sun_path limit, so we use a short /tmp
// base, NOT NSTemporaryDirectory which is long on macOS), a blocking line-based
// UDS test client, and a small JSON helper.

import Foundation
import XCTest
@testable import PlugsightDaemon
import PlugsightCore

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A raw UDS client that speaks one-JSON-object-per-line, for driving the server
/// exactly as a real UI/MCP client would. Blocking, with a receive timeout so a
/// missing notification fails fast instead of hanging the suite.
final class UDSTestClient {
    private let fd: Int32

    init(socketPath: String, timeoutSeconds: Int = 3) throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw TestClientError.socket(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path),
                     "socket path too long for sun_path (\(pathBytes.count) bytes)")
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(sock, sp, len)
            }
        }
        guard rc == 0 else {
            Darwin.close(sock)
            throw TestClientError.connect(errno)
        }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        self.fd = sock
    }

    /// Send a JSON object as one newline-terminated line.
    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var off = 0
            let base = raw.baseAddress!
            while off < line.count {
                let n = write(fd, base + off, line.count - off)
                if n <= 0 { throw TestClientError.write(errno) }
                off += n
            }
        }
    }

    /// Send a raw string (already framed or intentionally malformed) as one line.
    func sendRaw(_ text: String) throws {
        var line = Data(text.utf8)
        line.append(0x0A)
        _ = try line.withUnsafeBytes { raw -> Int in
            let n = write(fd, raw.baseAddress!, line.count)
            if n <= 0 { throw TestClientError.write(errno) }
            return n
        }
    }

    /// Read one newline-delimited line and parse it as JSON. Returns nil on EOF
    /// (server closed the connection) or timeout.
    func readLine() -> [String: Any]? {
        var buf = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }            // EOF or timeout
            if byte == 0x0A { break }
            buf.append(byte)
        }
        return (try? JSONSerialization.jsonObject(with: buf)) as? [String: Any]
    }

    /// True if the connection is closed by the peer (read returns 0/EOF).
    func isClosedByPeer() -> Bool {
        var byte: UInt8 = 0
        let n = read(fd, &byte, 1)
        return n == 0
    }

    func close() { Darwin.close(fd) }

    enum TestClientError: Error { case socket(Int32), connect(Int32), write(Int32) }
}

/// A short-lived temp directory under /tmp so the socket path fits sun_path (the
/// AF_UNIX limit is 104 bytes; NSTemporaryDirectory is far longer on macOS).
/// Returns the directory path; caller starts an APIServer against it and puts the
/// database file inside it.
func makeTempStateDir(file: StaticString = #file, line: UInt = #line) -> String {
    let name = "ps-" + String(UUID().uuidString.prefix(8))
    let dir = "/tmp/\(name)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// A pair of stores over one temp file database: the N2 `EventStore` (device +
/// event seeding via its public writers) and the N4 `APIStore` (alert/scan/score/
/// policy seeding + the API read/write surface). They share the file via WAL, so
/// each sees the other's commits — exactly the daemon-vs-API topology in prod.
struct TestDB {
    let path: String
    let event: EventStore
    let api: APIStore
}

func makeTestDB(inDir dir: String) throws -> TestDB {
    let path = (dir as NSString).appendingPathComponent("plugsight.db")
    let event = try EventStore(path: path)   // runs migrations
    let api = try APIStore(path: path)
    return TestDB(path: path, event: event, api: api)
}

extension UDSTestClient {
    /// Perform the auth.hello handshake with the given token; returns the hello
    /// result. Throws if the server did not accept the token.
    @discardableResult
    func hello(token: String, name: String = "test", kind: String = "cli") throws -> [String: Any] {
        try send(["jsonrpc": "2.0", "id": 0, "method": "auth.hello",
                  "params": ["token": token, "clientInfo": ["name": name, "kind": kind]]])
        guard let resp = readLine() else { throw NSError(domain: "hello", code: 1) }
        if resp["error"] != nil { throw NSError(domain: "hello-rejected", code: 2) }
        return resp
    }

    /// Send a request and read the one-line response.
    func call(id: Int, method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let resp = readLine() else { throw NSError(domain: "call", code: 1, userInfo: [NSLocalizedDescriptionKey: "no response to \(method)"]) }
        return resp
    }
}

/// Read the server's token from disk.
func readToken(_ server: APIServer) throws -> String {
    try String(contentsOfFile: server.tokenPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Connect and authenticate a client against the server.
func authedClient(_ server: APIServer, name: String = "test", kind: String = "cli") throws -> UDSTestClient {
    let c = try UDSTestClient(socketPath: server.socketPath)
    try c.hello(token: try readToken(server), name: name, kind: kind)
    return c
}

extension Dictionary where Key == String, Value == Any {
    /// Convenience: the JSON-RPC `result` object of a response, or nil.
    var rpcResult: [String: Any]? { self["result"] as? [String: Any] }
    /// Convenience: the JSON-RPC `error` object of a response, or nil.
    var rpcError: [String: Any]? { self["error"] as? [String: Any] }
}
