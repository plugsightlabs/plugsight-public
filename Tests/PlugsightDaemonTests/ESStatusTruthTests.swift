// ESStatusTruthTests.swift
//
// Unit 5: status.get must tell the truth about endpoint security. "active"
// requires a LIVE XPC handshake with the extension (the resolver, wired from
// ESExtensionXPCClient.handshakeActive); no resolver keeps the boot flag,
// which honest boot wiring sets false. The old code hardcoded the capability
// at boot, so an activated extension could never read active and a dead one
// could have read active forever.

import XCTest
import PlugsightCore
@testable import PlugsightDaemon

final class ESStatusTruthTests: XCTestCase {

    private func makeRouter(
        bootES: Bool = false,
        esActiveResolver: (@Sendable () -> Bool)? = nil
    ) throws -> Router {
        let dir = makeTempStateDir()
        let db = try makeTestDB(inDir: dir)
        return Router(
            store: db.api,
            broadcaster: EventBroadcaster(),
            daemonVersion: "test",
            capabilities: Capabilities(
                inputMonitoring: true, endpointSecurity: bootES, clamav: false
            ),
            startedAt: Date(),
            quarantineDirectory: dir,
            esActiveResolver: esActiveResolver
        )
    }

    func testLiveHandshakeReadsActive() throws {
        let router = try makeRouter(esActiveResolver: { true })
        XCTAssertEqual(try router.statusGet().permissions.esExtension, "active")
    }

    func testNoHandshakeReadsInactiveEvenWithBootFlagTrue() throws {
        // Even if boot wiring ever claimed ES at boot, a dead handshake wins:
        // the resolver is the truth.
        let router = try makeRouter(bootES: true, esActiveResolver: { false })
        XCTAssertEqual(try router.statusGet().permissions.esExtension, "inactive")
    }

    func testNoResolverKeepsTheBootFlagBehavior() throws {
        // Pure routing tests and ES-less daemons: unchanged reporting.
        XCTAssertEqual(try makeRouter(bootES: false).statusGet().permissions.esExtension, "inactive")
        XCTAssertEqual(try makeRouter(bootES: true).statusGet().permissions.esExtension, "active")
    }

    func testHandshakeStateChangesAreSeenLiveWithoutRestart() throws {
        let flag = LockedFlag()
        let router = try makeRouter(esActiveResolver: { flag.value })
        XCTAssertEqual(try router.statusGet().permissions.esExtension, "inactive")
        flag.value = true
        XCTAssertEqual(try router.statusGet().permissions.esExtension, "active",
                       "an extension activated while the daemon runs must show without a restart")
        flag.value = false
        XCTAssertEqual(try router.statusGet().permissions.esExtension, "inactive",
                       "a died extension must stop reading active")
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
