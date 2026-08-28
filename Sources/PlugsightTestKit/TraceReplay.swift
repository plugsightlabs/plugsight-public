// TraceReplay.swift
//
// N6 trace replay harness: turns a HID trace fixture
// (Tests/Fixtures/hid-traces/*.json) into an ordered `[CollectorEvent]` so the
// scorer engine is exercised via the real seam (02). Fixtures are loaded BY
// PATH (a URL relative to the test file's #filePath), exactly as N5 loaded
// Tests/Fixtures/iokit/*.json — zero Package.swift churn.
//
// Timestamp contract: the seam's `.attached(DeviceDescriptor)` carries no
// timestamp (a live source's attach IS "now"), so the scorer engine stamps
// attaches with an injected clock. For deterministic replay, `makeAttachClock`
// returns a stepping clock that yields the trace's attach times in order —
// the engine consults its clock exactly once per `.attached` event, keeping
// the two in lockstep.

import Foundation
import PlugsightCore

/// One record of a HID trace fixture, a CollectorEvent-equivalent.
public struct HIDTraceRecord: Codable, Equatable, Sendable {
    /// "attached" | "detached" | "inputActivity".
    public var type: String
    /// Milliseconds after `HIDTrace.baseDate`.
    public var atMs: Int
    /// Present when `type == "attached"`.
    public var device: DeviceDescriptor?
    /// Present when `type == "detached"`.
    public var deviceKey: String?
    /// Present when `type == "inputActivity"`; nil for the first key of a burst.
    public var interKeyIntervalMs: Int?

    public init(
        type: String,
        atMs: Int,
        device: DeviceDescriptor? = nil,
        deviceKey: String? = nil,
        interKeyIntervalMs: Int? = nil
    ) {
        self.type = type
        self.atMs = atMs
        self.device = device
        self.deviceKey = deviceKey
        self.interKeyIntervalMs = interKeyIntervalMs
    }
}

/// The on-disk fixture shape: a comment plus ordered records.
public struct HIDTraceFile: Codable, Sendable {
    public var comment: String?
    public var records: [HIDTraceRecord]

    public init(comment: String? = nil, records: [HIDTraceRecord]) {
        self.comment = comment
        self.records = records
    }
}

public enum TraceReplayError: Error, Equatable {
    case malformedRecord(String)
}

/// A loaded trace: seam events in order, plus the attach times the scorer's
/// stepping clock replays.
public struct HIDTrace: Sendable {
    /// All fixture offsets are relative to this instant (2026-01-01T00:00:00Z).
    public static let baseDate = Date(timeIntervalSince1970: 1_767_225_600)

    /// The seam events, in fixture order.
    public let events: [CollectorEvent]
    /// Timestamp of every `.attached` event, in order (the seam carries none).
    public let attachTimes: [Date]

    public init(events: [CollectorEvent], attachTimes: [Date]) {
        self.events = events
        self.attachTimes = attachTimes
    }

    /// Decode a fixture file into a trace.
    public static func load(from url: URL) throws -> HIDTrace {
        let file = try JSONDecoder().decode(HIDTraceFile.self, from: Data(contentsOf: url))
        var events: [CollectorEvent] = []
        var attachTimes: [Date] = []
        for record in file.records {
            let at = baseDate.addingTimeInterval(Double(record.atMs) / 1000)
            switch record.type {
            case "attached":
                guard let device = record.device else {
                    throw TraceReplayError.malformedRecord("attached record without device")
                }
                events.append(.attached(device))
                attachTimes.append(at)
            case "detached":
                guard let key = record.deviceKey else {
                    throw TraceReplayError.malformedRecord("detached record without deviceKey")
                }
                events.append(.detached(deviceKey: key, at: at))
            case "inputActivity":
                events.append(.inputActivity(InputTiming(at: at, interKeyIntervalMs: record.interKeyIntervalMs)))
            default:
                throw TraceReplayError.malformedRecord("unknown record type '\(record.type)'")
            }
        }
        return HIDTrace(events: events, attachTimes: attachTimes)
    }

    /// The real seam: an array-backed `DeviceEventSource` replaying this trace.
    public func makeSource() -> FakeDeviceEventSource {
        FakeDeviceEventSource(events: events)
    }

    /// Stepping clock for the scorer engine: returns `attachTimes` in order,
    /// then keeps returning the last one. Call exactly once per `.attached`.
    public func makeAttachClock() -> () -> Date {
        let times = attachTimes
        var index = 0
        return {
            guard !times.isEmpty else { return HIDTrace.baseDate }
            let at = times[min(index, times.count - 1)]
            index += 1
            return at
        }
    }
}
