// APIServer.swift
//
// The local API server (02): a Unix-domain-socket listener speaking one
// JSON-RPC 2.0 message per newline-terminated line. POSIX sockets + Foundation
// only, no HTTP dependency. The socket and the token file are 0600; the token is
// 32 random bytes generated with the state directory.
//
// Auth gate: the FIRST message on every connection must be `auth.hello` with the
// token. Anything else -> -32001 unauthorized and the connection CLOSES.

import Foundation
import PlugsightCore

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// One accepted client connection. Owns its fd, auth state, the actor string
/// derived from auth.hello, and the ids of its live tail subscriptions.
final class APIConnection {
    let fd: Int32
    private let writeLock = NSLock()
    var authenticated = false
    var actor: String = "cli"
    var subscriptionIDs: Set<String> = []
    private(set) var closed = false

    init(fd: Int32) { self.fd = fd }

    /// Write one framed line (the payload plus a trailing newline). Serialized so
    /// concurrent notifications and responses never interleave on the wire.
    func sendLine(_ payload: Data) {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { return }
        var line = payload
        line.append(0x0A)
        line.withUnsafeBytes { raw in
            var off = 0
            let base = raw.baseAddress!
            while off < line.count {
                let n = write(fd, base + off, line.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    func close() {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

public final class APIServer {
    public let socketPath: String
    public let tokenPath: String

    private let store: APIStore
    private let stateDirectory: String
    private let router: Router
    private let broadcaster = EventBroadcaster()

    /// Fired after a successful policy.set or trust.set commit (forwarded to
    /// the router). The daemon wires the ES policy pusher here so the
    /// extension's cache reflects an operator change immediately.
    public var onPolicyOrTrustChanged: (@Sendable () -> Void)? {
        get { router.onPolicyOrTrustChanged }
        set { router.onPolicyOrTrustChanged = newValue }
    }
    private let startedAt = Date()

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var running = false
    private let connLock = NSLock()
    private var connections: Set<ObjectIdentifier> = []
    private var connObjects: [ObjectIdentifier: APIConnection] = [:]
    private var token: String = ""

    /// - Parameters:
    ///   - store: the ONE `EventStore` (N8 unification) — the daemon's analyzer,
    ///     the scan orchestrator, and the API layer all write through it. Every
    ///     event append on it (from any writer) fans out over `event.appended`
    ///     via the observer hooked here.
    ///   - stateDirectory: where the socket and token live (0600). Base dir is
    ///     injectable so tests use a short temp path under sun_path's 104 bytes.
    ///   - quarantineDirectory: where quarantined files + sidecars live (02).
    ///     Defaults to the real Application Support path; injectable so tests point
    ///     it at a temp slot they control.
    public init(
        store eventStore: EventStore,
        stateDirectory: String,
        daemonVersion: String,
        capabilities: Capabilities,
        quarantineDirectory: String? = nil,
        scanOrchestrator: ScanOrchestrator? = nil,
        clamavResolver: (@Sendable () -> String?)? = nil,
        definitionsAgeResolver: (@Sendable () -> Int?)? = nil,
        scannerInstaller: ScannerInstaller? = nil,
        inputMonitoringResolver: (@Sendable () -> Bool)? = nil,
        esActiveResolver: (@Sendable () -> Bool)? = nil
    ) {
        self.store = APIStore(store: eventStore)
        self.stateDirectory = stateDirectory
        self.socketPath = (stateDirectory as NSString).appendingPathComponent("plugsightd.sock")
        self.tokenPath = (stateDirectory as NSString).appendingPathComponent("api-token")
        let quarantineDir = quarantineDirectory
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Plugsight/quarantine")
        // When an orchestrator is wired, `scan.start` drives a REAL scan (N8b Gap
        // A) with a config resolved from the LIVE policy rows at scan time (Gap B),
        // so a `policy.set` takes effect for subsequent scans.
        let apiStore = self.store
        let coordinator = scanOrchestrator.map { orchestrator in
            ScanCoordinator(
                orchestrator: orchestrator,
                quarantineDirectory: quarantineDir,
                configForScan: {
                    ScanConfigResolver.resolve(
                        base: .defaults(quarantineDirectory: quarantineDir),
                        policyRaw: (try? apiStore.policyRaw()) ?? [:]
                    )
                }
            )
        }
        self.router = Router(
            store: store,
            broadcaster: broadcaster,
            daemonVersion: daemonVersion,
            capabilities: capabilities,
            startedAt: startedAt,
            quarantineDirectory: quarantineDir,
            scanCoordinator: coordinator,
            // status.get answers scanner availability from this resolver when
            // wired, so an engine installed mid-run is seen without a restart.
            clamavResolver: clamavResolver,
            // status.get reports the REAL definitions age from this resolver, and
            // scanner.install drives the injected installer (onboarding step).
            definitionsAgeResolver: definitionsAgeResolver,
            scannerInstaller: scannerInstaller,
            // status.get re-checks the Input Monitoring permission through this
            // resolver, so a grant made while the daemon runs is seen live.
            inputMonitoringResolver: inputMonitoringResolver,
            // status.get reports endpoint security "active" ONLY while this
            // resolver sees a live, acknowledged XPC handshake with the ES
            // extension (boot wiring wraps ESExtensionXPCClient.handshakeActive).
            esActiveResolver: esActiveResolver
        )
        // The one bus: every committed append on the shared store — analyzer,
        // scans, API mutations, retention markers — fans out to subscribers.
        let broadcaster = self.broadcaster
        eventStore.addEventObserver { event in
            broadcaster.publish(event)
        }
    }

    /// Convenience: open (and migrate) the store at `databasePath` first.
    public convenience init(
        databasePath: String,
        stateDirectory: String,
        daemonVersion: String,
        capabilities: Capabilities,
        quarantineDirectory: String? = nil,
        scanOrchestrator: ScanOrchestrator? = nil,
        clamavResolver: (@Sendable () -> String?)? = nil,
        definitionsAgeResolver: (@Sendable () -> Int?)? = nil,
        scannerInstaller: ScannerInstaller? = nil,
        inputMonitoringResolver: (@Sendable () -> Bool)? = nil
    ) throws {
        self.init(
            store: try EventStore(path: databasePath),
            stateDirectory: stateDirectory,
            daemonVersion: daemonVersion,
            capabilities: capabilities,
            quarantineDirectory: quarantineDirectory,
            scanOrchestrator: scanOrchestrator,
            clamavResolver: clamavResolver,
            definitionsAgeResolver: definitionsAgeResolver,
            scannerInstaller: scannerInstaller,
            inputMonitoringResolver: inputMonitoringResolver
        )
    }

    // MARK: - Lifecycle

    public func start() throws {
        try ensureStateDirectory()
        try ensureToken()
        try openSocket()
        running = true
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.stackSize = 1 << 20
        t.start()
        acceptThread = t
    }

    /// Fan an appended event out to matching tail subscriptions. The wired daemon
    /// (N8) calls this after the collector/analyzer appends to the store; API
    /// mutations fan out through the same bus.
    public func publish(_ event: StoredEvent) {
        broadcaster.publish(event)
    }

    public func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        unlink(socketPath)
        connLock.lock()
        let all = Array(connObjects.values)
        connLock.unlock()
        for c in all { c.close() }
    }

    // MARK: - State dir, token, socket

    private func ensureStateDirectory() throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: stateDirectory, isDirectory: &isDir) {
            try FileManager.default.createDirectory(
                atPath: stateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func ensureToken() throws {
        if let existing = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { token = trimmed; return }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        token = hex
        // Create 0600 up front (open with mode) so the secret is never briefly
        // world-readable.
        unlink(tokenPath)
        let fd = open(tokenPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw APIServerError.tokenWrite(errno) }
        defer { Darwin.close(fd) }
        let data = Data(hex.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        chmod(tokenPath, 0o600)
    }

    private func openSocket() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw APIServerError.socket(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw APIServerError.pathTooLong(socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { p in
                for (i, b) in pathBytes.enumerated() { p[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, len)
            }
        }
        guard rc == 0 else { Darwin.close(fd); throw APIServerError.bind(errno) }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else { Darwin.close(fd); throw APIServerError.listen(errno) }
        listenFD = fd
    }

    // MARK: - Accept + connection loops

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if running { continue } else { break }
            }
            let conn = APIConnection(fd: clientFD)
            connLock.lock()
            connObjects[ObjectIdentifier(conn)] = conn
            connLock.unlock()
            let t = Thread { [weak self] in self?.connectionLoop(conn) }
            t.stackSize = 1 << 20
            t.start()
        }
    }

    private func connectionLoop(_ conn: APIConnection) {
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)
        readLoop: while running {
            let n = read(conn.fd, &readBuf, readBuf.count)
            if n <= 0 { break }
            buffer.append(contentsOf: readBuf[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let keepOpen = handleLine(Data(lineData), conn: conn)
                if !keepOpen { break readLoop }
            }
        }
        cleanup(conn)
    }

    /// Process one line. Returns false when the connection must be closed
    /// (unauthorized first message, or a bad token).
    private func handleLine(_ line: Data, conn: APIConnection) -> Bool {
        // Ignore blank keepalive lines.
        if line.isEmpty { return true }

        let request: RPCRequest
        do {
            request = try JSONDecoder().decode(RPCRequest.self, from: line)
        } catch {
            let err = APIError(code: -32700, message: "Parse error: each line must be one JSON-RPC 2.0 object.", kind: .invalidParams)
            conn.sendLine(RPCEncoder.error(id: nil, err))
            return true
        }

        // Auth gate: the first message must be auth.hello.
        if !conn.authenticated {
            guard request.method == "auth.hello" else {
                conn.sendLine(RPCEncoder.error(id: request.id, .unauthorized()))
                return false   // close the connection
            }
            do {
                let data = try router.handleHello(request: request, conn: conn, token: token)
                conn.sendLine(data)
                return true
            } catch let e as APIError {
                conn.sendLine(RPCEncoder.error(id: request.id, e))
                // A bad token closes the connection.
                return e.kind != .unauthorized
            } catch {
                conn.sendLine(RPCEncoder.error(id: request.id, .unauthorized()))
                return false
            }
        }

        // Authenticated dispatch.
        do {
            let data = try router.handle(request: request, conn: conn)
            conn.sendLine(data)
        } catch let e as APIError {
            conn.sendLine(RPCEncoder.error(id: request.id, e))
        } catch {
            let e = APIError(code: -32603, message: "Internal error handling \(request.method).", kind: .conflict)
            conn.sendLine(RPCEncoder.error(id: request.id, e))
        }
        return true
    }

    private func cleanup(_ conn: APIConnection) {
        broadcaster.remove(ids: conn.subscriptionIDs)
        conn.close()
        connLock.lock()
        connObjects.removeValue(forKey: ObjectIdentifier(conn))
        connLock.unlock()
    }

    enum APIServerError: Error {
        case socket(Int32), bind(Int32), listen(Int32), tokenWrite(Int32), pathTooLong(String)
    }
}
