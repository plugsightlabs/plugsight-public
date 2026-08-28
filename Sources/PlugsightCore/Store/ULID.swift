// ULID.swift
//
// A small monotonic ULID generator (docs/spec/06, 07): 128 bits = 48-bit
// millisecond timestamp + 80 bits of randomness, rendered as 26 Crockford
// base32 characters. Two properties matter for the store:
//
//  1. Time-ordered: because the timestamp occupies the high bits and the
//     Crockford alphabet is in ascending ASCII order, lexicographic string
//     comparison equals chronological order. This is what lets `events` and
//     `devices` use `WHERE id < ?` cursor pagination on the id column alone.
//  2. Monotonic within a millisecond: if two ids are minted in the same ms,
//     the 80-bit random field is incremented rather than re-rolled, so ids
//     minted later in the same ms still sort after earlier ones.

import Foundation

/// Crockford base32 alphabet (excludes I, L, O, U). Ascending value order maps
/// to ascending ASCII order, which is what keeps ULID strings sortable.
private let crockford: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

/// Thread-safe, monotonic ULID string generator.
public final class ULIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTimeMs: UInt64 = 0
    private var lastRandom: [UInt8] = Array(repeating: 0, count: 10)
    private var seeded = false

    public init() {}

    /// Mint the next ULID string (26 chars). `now` is injectable for tests.
    public func next(now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }

        let timeMs = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded(.down)))
        if seeded && timeMs <= lastTimeMs {
            // Same or backwards clock: keep the last timestamp and increment the
            // 80-bit random field so the new id still sorts strictly after.
            incrementRandom()
        } else {
            lastTimeMs = timeMs
            for i in 0..<10 { lastRandom[i] = UInt8.random(in: 0...255) }
            seeded = true
        }
        return Self.encodeTime(lastTimeMs) + Self.encodeRandom(lastRandom)
    }

    /// Increment the 10-byte random field as a big-endian 80-bit integer.
    private func incrementRandom() {
        var i = 9
        while i >= 0 {
            if lastRandom[i] == 0xFF {
                lastRandom[i] = 0
                i -= 1
            } else {
                lastRandom[i] += 1
                return
            }
        }
        // 80-bit overflow within one millisecond is not reachable in practice.
    }

    /// Encode a 48-bit millisecond timestamp as 10 Crockford chars.
    static func encodeTime(_ ms: UInt64) -> String {
        var value = ms & 0xFFFF_FFFF_FFFF // 48 bits
        var chars = [Character](repeating: "0", count: 10)
        var i = 9
        while i >= 0 {
            chars[i] = crockford[Int(value & 0x1F)]
            value >>= 5
            i -= 1
        }
        return String(chars)
    }

    /// Encode 80 bits (10 bytes) of randomness as 16 Crockford chars.
    static func encodeRandom(_ bytes: [UInt8]) -> String {
        var chars = [Character]()
        chars.reserveCapacity(16)
        var buffer: UInt = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(crockford[Int((buffer >> UInt(bits)) & 0x1F)])
            }
        }
        // 80 is divisible by 5, so no leftover bits remain.
        return String(chars)
    }
}
