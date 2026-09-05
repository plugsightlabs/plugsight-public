// ESClientPlumbing.swift
//
// The THIN Endpoint Security client (02, 07). Everything here is transport:
// subscribe, extract plain values from the C message, call the PURE decision
// (PlugsightESCore), respond, forward. No branching policy logic lives in
// this file — if you are adding an `if` about trust, freshness, or deadlines
// here, it belongs in PlugsightESCore behind a test.
//
// CANNOT run in CI: es_new_client requires root plus the
// com.apple.developer.endpoint-security.client entitlement (L5). The compile
// is the CI gate; the live path is the recorded manual session
// (ESExtension/README.md).

import EndpointSecurity
import Foundation
import os
import PlugsightESCore

public final class PlugsightESClient {
    public typealias EventSink = @Sendable (ESObservedEvent) -> Void

    private let log = Logger(subsystem: "com.plugsight.esext", category: "es-client")
    private let cacheBox: ESPolicyCacheBox
    private let eventSink: EventSink
    private var client: OpaquePointer?

    /// - Parameters:
    ///   - cacheBox: the policy cache the XPC listener keeps updated.
    ///   - eventSink: receives compact events for forwarding to the daemon.
    public init(cacheBox: ESPolicyCacheBox, eventSink: @escaping EventSink) {
        self.cacheBox = cacheBox
        self.eventSink = eventSink
    }

    /// Create the ES client and subscribe to 02's event set.
    public func start() -> es_new_client_result_t {
        let result = es_new_client(&client) { [cacheBox, eventSink, log] client, message in
            Self.handle(
                client: client, message: message,
                cacheBox: cacheBox, eventSink: eventSink, log: log
            )
        }
        guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let client else { return result }
        var events: [es_event_type_t] = [
            ES_EVENT_TYPE_NOTIFY_IOKIT_OPEN,
            ES_EVENT_TYPE_NOTIFY_MOUNT,
            ES_EVENT_TYPE_NOTIFY_UNMOUNT,
            ES_EVENT_TYPE_AUTH_MOUNT,
        ]
        if es_subscribe(client, &events, UInt32(events.count)) != ES_RETURN_SUCCESS {
            log.error("es_subscribe failed")
        }
        return result
    }

    public func stop() {
        if let client {
            es_unsubscribe_all(client)
            es_delete_client(client)
        }
        client = nil
    }

    // MARK: - Message handling (static: no self, no locks, no surprises)

    private static func handle(
        client: OpaquePointer,
        message: UnsafePointer<es_message_t>,
        cacheBox: ESPolicyCacheBox,
        eventSink: EventSink,
        log: Logger
    ) {
        let now = Date()
        switch message.pointee.event_type {
        case ES_EVENT_TYPE_AUTH_MOUNT:
            // THE enforcement point. Decide from the local cache ONLY, inside
            // the deadline budget, and respond immediately (02). A nobrowse
            // mount (the daemon's own private scan remount) is exempt from the
            // hold by decision-layer rule, or the flow would deadlock.
            let bsd = bsdName(fromMountFrom: message.pointee.event.mount.statfs)
            let mountPath = mountPoint(from: message.pointee.event.mount.statfs)
            let snapshot = cacheBox.snapshot
            let decision = MountHoldDecider.decide(
                cache: snapshot,
                volumeDeviceKey: bsd.flatMap { snapshot?.deviceKey(forBSDName: $0) },
                now: now,
                budget: deadlineBudget(of: message, now: now),
                nobrowse: isNobrowse(message.pointee.event.mount.statfs)
            )
            let esResult = decision.isDeny ? ES_AUTH_RESULT_DENY : ES_AUTH_RESULT_ALLOW
            // cache:false — every mount must come back through the decision.
            if es_respond_auth_result(client, message, esResult, false) != ES_RESPOND_RESULT_SUCCESS {
                log.error("es_respond_auth_result failed for \(bsd ?? "?", privacy: .public)")
            }
            log.log(
                "AUTH_MOUNT \(bsd ?? "?", privacy: .public) -> \(decision.isDeny ? "DENY" : "ALLOW", privacy: .public) (\(decision.reason.rawValue, privacy: .public))"
            )
            eventSink(ESObservedEvent(
                kind: .authMountDecision, timestamp: now, bsdName: bsd,
                mountPath: mountPath, decision: decision
            ))

        case ES_EVENT_TYPE_NOTIFY_MOUNT:
            eventSink(ESObservedEvent(
                kind: .mount, timestamp: now,
                bsdName: bsdName(fromMountFrom: message.pointee.event.mount.statfs),
                mountPath: mountPoint(from: message.pointee.event.mount.statfs),
                nobrowse: isNobrowse(message.pointee.event.mount.statfs)
            ))

        case ES_EVENT_TYPE_NOTIFY_UNMOUNT:
            eventSink(ESObservedEvent(
                kind: .unmount, timestamp: now,
                bsdName: bsdName(fromMountFrom: message.pointee.event.unmount.statfs),
                mountPath: mountPoint(from: message.pointee.event.unmount.statfs)
            ))

        case ES_EVENT_TYPE_NOTIFY_IOKIT_OPEN:
            eventSink(ESObservedEvent(
                kind: .iokitOpen, timestamp: now,
                pid: pid(of: message.pointee.process),
                processPath: string(from: message.pointee.process.pointee.executable.pointee.path)
            ))

        default:
            // Unsubscribed event type. If it is somehow an AUTH event, the
            // fail-open law applies: answer ALLOW rather than stall it.
            if message.pointee.action_type == ES_ACTION_TYPE_AUTH {
                _ = es_respond_auth_result(client, message, ES_AUTH_RESULT_ALLOW, false)
                log.error("unexpected AUTH event \(message.pointee.event_type.rawValue) — allowed (fail-open)")
            }
        }
    }

    // MARK: - Plain-value extraction helpers

    /// Remaining budget from the message's mach-time deadline.
    private static func deadlineBudget(
        of message: UnsafePointer<es_message_t>, now: Date
    ) -> ESDeadlineBudget {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nowTicks = mach_absolute_time()
        let deadlineTicks = message.pointee.deadline
        let remainingNanos: UInt64 = deadlineTicks > nowTicks
            ? (deadlineTicks - nowTicks) * UInt64(timebase.numer) / UInt64(timebase.denom)
            : 0
        return ESDeadlineBudget(
            deadline: now.addingTimeInterval(TimeInterval(remainingNanos) / 1e9)
        )
    }

    private static func string(from token: es_string_token_t) -> String? {
        guard token.length > 0, let data = token.data else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: data, count: token.length),
            as: UTF8.self
        )
    }

    /// "/dev/disk4s1" -> "disk4s1" (the pure layer strips /dev/ too; doing it
    /// here keeps forwarded events uniform).
    private static func bsdName(fromMountFrom statfs: UnsafeMutablePointer<statfs>?) -> String? {
        guard let statfs else { return nil }
        let raw = withUnsafeBytes(of: statfs.pointee.f_mntfromname) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        guard !raw.isEmpty else { return nil }
        return raw.hasPrefix("/dev/") ? String(raw.dropFirst("/dev/".count)) : raw
    }

    /// MNT_DONTBROWSE set on the mount's flags: the volume never appears in
    /// Finder. The daemon's private scan remount mounts nobrowse.
    private static func isNobrowse(_ statfs: UnsafeMutablePointer<statfs>?) -> Bool {
        guard let statfs else { return false }
        return statfs.pointee.f_flags & UInt32(MNT_DONTBROWSE) != 0
    }

    private static func mountPoint(from statfs: UnsafeMutablePointer<statfs>?) -> String? {
        guard let statfs else { return nil }
        let raw = withUnsafeBytes(of: statfs.pointee.f_mntonname) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return raw.isEmpty ? nil : raw
    }

    private static func pid(of process: UnsafeMutablePointer<es_process_t>) -> Int32 {
        audit_token_to_pid(process.pointee.audit_token)
    }
}
