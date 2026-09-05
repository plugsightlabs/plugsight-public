// ESLinkTests.swift
//
// The daemon<->extension link, exercised IN PROCESS over a real XPC
// connection (NSXPCListener.anonymous): policy pushes land in the listener's
// cache and are acknowledged (the live-handshake signal), extension events
// flow back into the daemon client, and the pusher assembles honest
// snapshots from its providers. The production Mach-service dial and the
// code-signing requirement need the entitled extension and stay on the
// manual dev-machine gate (ESExtension/README.md); everything decided here
// is the same code that runs there.

import XCTest
import PlugsightCore
import PlugsightESCore
@testable import PlugsightDaemon

/// In-process stand-in for the extension's XPC side: accepts unconditionally
/// (no code signing in-process), records pushed snapshots, acks per
/// `ackValue`, and can forward events back over the accepted connection.
private final class ExtensionListenerDouble: NSObject, NSXPCListenerDelegate, ESExtensionXPCProtocol {
    let listener = NSXPCListener.anonymous()
    let lock = NSLock()
    var received: [ESPolicySnapshot] = []
    var ackValue = true
    var connections: [NSXPCConnection] = []
    var onPush: ((ESPolicySnapshot) -> Void)?

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ESExtensionXPCProtocol.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: ESDaemonEventSinkProtocol.self)
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.resume()
        return true
    }

    func pushPolicy(_ payload: Data, acknowledgement: @escaping (Bool) -> Void) {
        guard let snapshot = try? ESWire.decode(ESPolicySnapshot.self, from: payload) else {
            acknowledgement(false)
            return
        }
        lock.lock()
        received.append(snapshot)
        let ack = ackValue
        lock.unlock()
        acknowledgement(ack)
        onPush?(snapshot)
    }

    /// Push one event to every connected daemon, as the real listener's
    /// forward(_:) does.
    func forward(_ event: ESObservedEvent) throws {
        let payload = try ESWire.encode(event)
        lock.lock()
        let conns = connections
        lock.unlock()
        for connection in conns {
            (connection.remoteObjectProxy as? ESDaemonEventSinkProtocol)?.deliverEvent(payload)
        }
    }
}

final class ESLinkTests: XCTestCase {

    private func makeSnapshot(hold: Bool = true) -> ESPolicySnapshot {
        ESPolicySnapshot(
            holdUntilScanned: hold,
            trustByDeviceKey: ["serial:1:2:X": .none],
            bsdNameToDeviceKey: ["disk9": "serial:1:2:X"],
            pushedAt: Date()
        )
    }

    func testPushReachesTheListenerAndActivatesTheHandshake() throws {
        let double = ExtensionListenerDouble()
        let client = ESExtensionXPCClient(endpoint: .listenerEndpoint(double.listener.endpoint))
        defer { client.stop() }

        let pushed = expectation(description: "push landed")
        double.onPush = { _ in pushed.fulfill() }
        client.connect()
        XCTAssertFalse(client.handshakeActive, "no ack yet: the handshake must not read active")

        client.push(makeSnapshot())
        wait(for: [pushed], timeout: 5)

        // The ack races the push landing; poll briefly for it.
        let deadline = Date().addingTimeInterval(5)
        while !client.handshakeActive && Date() < deadline {
            usleep(20_000)
        }
        XCTAssertTrue(client.handshakeActive, "an acknowledged push must read as a live handshake")
        double.lock.lock()
        let received = double.received
        double.lock.unlock()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.bsdNameToDeviceKey["disk9"], "serial:1:2:X")
    }

    func testRejectedPushNeverActivatesTheHandshake() throws {
        let double = ExtensionListenerDouble()
        double.ackValue = false
        let client = ESExtensionXPCClient(endpoint: .listenerEndpoint(double.listener.endpoint))
        defer { client.stop() }

        let pushed = expectation(description: "push landed")
        double.onPush = { _ in pushed.fulfill() }
        client.connect()
        client.push(makeSnapshot())
        wait(for: [pushed], timeout: 5)

        // Give any (wrong) ack path a moment, then assert it never happened.
        usleep(100_000)
        XCTAssertFalse(client.handshakeActive, "a rejected push is NOT a live handshake")
    }

    func testHandshakeDecaysAfterTheAckTTL() throws {
        let double = ExtensionListenerDouble()
        // Injected clock: jumps forward past the TTL after the ack lands.
        let clockLock = NSLock()
        var nowOffset: TimeInterval = 0
        let client = ESExtensionXPCClient(
            endpoint: .listenerEndpoint(double.listener.endpoint),
            ackTTL: 60,
            clock: {
                clockLock.lock()
                defer { clockLock.unlock() }
                return Date().addingTimeInterval(nowOffset)
            }
        )
        defer { client.stop() }

        client.connect()
        client.push(makeSnapshot())
        let deadline = Date().addingTimeInterval(5)
        while !client.handshakeActive && Date() < deadline { usleep(20_000) }
        XCTAssertTrue(client.handshakeActive)

        clockLock.lock(); nowOffset = 120; clockLock.unlock()
        XCTAssertFalse(client.handshakeActive,
                       "an ack older than the TTL must not read as active (a wedged extension is inactive)")
    }

    func testExtensionEventsFlowIntoTheDaemonClient() throws {
        let double = ExtensionListenerDouble()
        let client = ESExtensionXPCClient(endpoint: .listenerEndpoint(double.listener.endpoint))
        defer { client.stop() }

        let delivered = expectation(description: "event delivered")
        let receivedLock = NSLock()
        var receivedEvents: [ESObservedEvent] = []
        client.onEvent = { event in
            receivedLock.lock()
            receivedEvents.append(event)
            receivedLock.unlock()
            delivered.fulfill()
        }
        // A push first, so the double has an accepted connection to talk back on.
        let pushed = expectation(description: "push landed")
        double.onPush = { _ in pushed.fulfill() }
        client.connect()
        client.push(makeSnapshot())
        wait(for: [pushed], timeout: 5)

        let event = ESObservedEvent(
            kind: .authMountDecision, timestamp: Date(), bsdName: "disk9",
            decision: .deny(.untrustedHold)
        )
        try double.forward(event)
        wait(for: [delivered], timeout: 5)

        receivedLock.lock()
        let events = receivedEvents
        receivedLock.unlock()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .authMountDecision)
        XCTAssertEqual(events.first?.decision, .deny(.untrustedHold))
    }

    func testClientToleratesAnAbsentServiceWithoutActivating() {
        // Dial a Mach service that does not exist (the entitlement-pending
        // reality on every machine today): nothing crashes, nothing activates.
        let client = ESExtensionXPCClient(
            endpoint: .machService(name: "com.plugsight.esext.test-absent")
        )
        defer { client.stop() }
        client.connect()
        client.push(makeSnapshot())
        usleep(100_000)
        XCTAssertFalse(client.handshakeActive)
    }
}
