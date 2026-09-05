import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import PlugsightAppCore

/// A minimal in-process newline-JSON-RPC server over a real Unix socket, enough
/// for transport-behavior tests (auth.hello, events.tail, status.get). Runs its
/// accept/read loop on a plain thread so it never touches the Swift concurrency
/// pool the client under test runs on.
private final class LineServer: @unchecked Sendable {
    let stateDir: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "lineserver")

    init() throws {
        stateDir = NSTemporaryDirectory() + "plugsight-lineserver-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try "test-token".write(toFile: stateDir + "/api-token", atomically: true, encoding: .utf8)
        let path = stateDir + "/plugsightd.sock"

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listenFD >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: capacity) { raw in
                bytes.withUnsafeBufferPointer { src in raw.update(from: src.baseAddress!, count: bytes.count) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let fd = listenFD
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        precondition(rc == 0, "bind failed: \(errno)")
        precondition(listen(listenFD, 4) == 0)

        queue.async { [listenFD] in
            while true {
                let client = accept(listenFD, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { Self.serve(client) }
            }
        }
    }

    deinit { if listenFD >= 0 { close(listenFD) } }

    /// Answer every request with a canned result keyed by method. Requests are
    /// answered immediately; the server pushes nothing unsolicited, so a pump
    /// window on the client side is pure idle waiting.
    private static func serve(_ fd: Int32) {
        var buffer = Data()
        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { close(fd); return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = obj["id"] as? Int, let method = obj["method"] as? String else { continue }
                let result: Any
                switch method {
                case "auth.hello":
                    result = ["daemonVersion": "1.0.1", "apiVersion": 1]
                case "events.tail":
                    result = ["subscriptionId": "sub_test"]
                case "status.get":
                    result = [
                        "monitoring": "active", "daemonVersion": "1.0.1",
                        "permissions": ["inputMonitoring": true, "esExtension": "inactive"],
                        "scanner": ["available": true, "engine": "clamdscan"],
                        "devicesPresent": 1, "activeAlerts": 0, "monitoringGaps": [],
                    ] as [String: Any]
                default:
                    result = [:] as [String: Any]
                }
                let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
                var data = try! JSONSerialization.data(withJSONObject: reply)
                data.append(0x0A)
                data.withUnsafeBytes { raw in
                    _ = write(fd, raw.baseAddress, raw.count)
                }
            }
        }
    }
}

/// Transport-level checks that need no daemon. Full response-shape parity is an
/// integration concern (a running daemon), out of scope for the unit gate.
final class LiveAPIClientTests: XCTestCase {

    // The eternal-skeleton regression (wave 5, live-walk defect 3): while the
    // event stream holds a pump window open on the shared actor, an RPC must
    // still complete promptly. Before the sliced-pump fix, getStatus queued
    // behind the FULL pump window (20 s in production), so the inspector's 4+
    // sequential RPCs took minutes and the pane skeleton looked permanent.
    func testRPCCompletesPromptlyWhileEventPumpIsOpen() async throws {
        let server = try LineServer()
        let client = LiveAPIClient(stateDirectory: server.stateDir)
        _ = try await client.tailEvents(deviceId: nil, kinds: nil, severity: nil) { _ in }

        // Hold a 10 s pump window open, then issue an RPC into the same actor.
        let pump = Task { try await client.pumpEvents(waitSeconds: 10) }
        try await Task.sleep(nanoseconds: 300_000_000)  // pump is mid-window

        let started = Date()
        _ = try await client.getStatus()
        let elapsed = Date().timeIntervalSince(started)
        pump.cancel()

        XCTAssertLessThan(elapsed, 3.0,
            "an RPC issued during a pump window must complete within a slice, "
            + "not queue behind the whole window (took \(elapsed)s)")
    }

    // 9b: no token/socket present → daemon_unreachable with the literal fix.
    func testMissingDaemonSurfacesDaemonUnreachable() async {
        let tmp = NSTemporaryDirectory() + "plugsight-live-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let client = LiveAPIClient(stateDirectory: tmp)
        do {
            _ = try await client.getStatus()
            XCTFail("expected daemon_unreachable")
        } catch let e as APIError {
            XCTAssertEqual(e.kind, .daemonUnreachable)
            XCTAssertTrue(e.message.contains("Start Plugsight"))
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    // The canonical error message doubles as the recovery a human can follow.
    func testDaemonUnreachableMessageIsSelfSufficient() {
        XCTAssertTrue(APIError.daemonUnreachable.message.contains("Applications"))
    }
}
