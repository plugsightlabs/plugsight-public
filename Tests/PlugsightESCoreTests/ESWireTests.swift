// ESWireTests.swift
//
// N12 (02): events flow extension -> daemon as compact structs; cached policy
// flows daemon -> extension. The wire types live in the pure layer so both
// sides share one definition and CI can round-trip them without the ES
// framework. Decode failures on the receiving side are dropped-and-logged
// (a bad payload degrades to a stale cache, which fails open — never a crash).

import XCTest
import PlugsightCore
@testable import PlugsightESCore

final class ESWireTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_756_000_000)

    func testObservedEventRoundTrips() throws {
        let event = ESObservedEvent(
            kind: .authMountDecision,
            timestamp: now,
            bsdName: "disk4s1",
            mountPath: "/Volumes/UNTITLED",
            pid: 123,
            processPath: "/usr/libexec/mount_helper",
            decision: .deny(.untrustedHold)
        )
        let data = try ESWire.encode(event)
        let back = try ESWire.decode(ESObservedEvent.self, from: data)
        XCTAssertEqual(back, event)
    }

    func testMinimalEventOmitsOptionals() throws {
        let event = ESObservedEvent(kind: .unmount, timestamp: now)
        let back = try ESWire.decode(ESObservedEvent.self, from: ESWire.encode(event))
        XCTAssertEqual(back, event)
        XCTAssertNil(back.bsdName)
        XCTAssertNil(back.decision)
    }

    func testPolicySnapshotRoundTrips() throws {
        let snapshot = ESPolicySnapshot(
            holdUntilScanned: true,
            trustByDeviceKey: ["k1": .trusted, "k2": .flagged],
            bsdNameToDeviceKey: ["disk4": "k1"],
            pushedAt: now
        )
        let back = try ESWire.decode(
            ESPolicySnapshot.self, from: ESWire.encode(snapshot)
        )
        XCTAssertEqual(back, snapshot)
    }

    func testGarbagePayloadThrowsInsteadOfCrashing() {
        XCTAssertThrowsError(
            try ESWire.decode(ESPolicySnapshot.self, from: Data("not json".utf8))
        )
    }

    func testEventKindsCoverTheSubscribedSet() {
        // 02's subscription list: IOKIT_OPEN, MOUNT, UNMOUNT notify + the
        // AUTH_MOUNT decision record.
        XCTAssertEqual(
            Set(ESObservedEvent.Kind.allCases),
            Set([.iokitOpen, .mount, .unmount, .authMountDecision])
        )
    }
}
