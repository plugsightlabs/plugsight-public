// UDSConnection.swift
//
// A minimal blocking Unix-domain-socket connection with newline framing, matching
// the daemon's transport (02): each JSON-RPC message is one line terminated by
// '\n'. Reads buffer until a newline; a deadline bounds the wait so the long-poll
// tail and a dead daemon both return in bounded time rather than hanging.

import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

enum UDSError: Error { case socket(Int32), connect(Int32), pathTooLong, closed }

final class UDSConnection {
    private let fd: Int32
    private var readBuffer = Data()
    private(set) var isOpen = true

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UDSError.socket(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else { close(fd); throw UDSError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: capacity) { raw in
                pathBytes.withUnsafeBufferPointer { src in
                    raw.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard rc == 0 else { close(fd); throw UDSError.connect(errno) }
    }

    deinit { if isOpen { close(fd) } }

    func closeConnection() {
        if isOpen { close(fd); isOpen = false }
    }

    /// Write one message as a single '\n'-terminated line.
    func writeLine(_ data: Data) throws {
        guard isOpen else { throw UDSError.closed }
        var payload = data
        payload.append(0x0A)  // '\n'
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < payload.count {
                let n = write(fd, base + offset, payload.count - offset)
                if n <= 0 { isOpen = false; throw UDSError.closed }
                offset += n
            }
        }
    }

    /// Read one line (without the trailing newline), or nil past the deadline.
    func readLine(deadline: Date) throws -> Data? {
        while isOpen {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }

            // Bound the blocking read with select() so a silent daemon can't hang us.
            var readfds = fd_set()
            fdZero(&readfds); fdSet(fd, &readfds)
            var tv = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000))
            let ready = select(fd + 1, &readfds, nil, nil, &tv)
            if ready == 0 { return nil }          // timed out
            if ready < 0 { isOpen = false; throw UDSError.closed }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { isOpen = false; return nil }   // EOF
            if n < 0 { isOpen = false; throw UDSError.closed }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
        return nil
    }
}

// fd_set helpers (portable across Darwin/Glibc).
private func fdZero(_ set: inout fd_set) { set = fd_set() }
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let offset = Int(fd) / 32
    let mask = Int32(1 << (Int(fd) % 32))
    withUnsafeMutablePointer(to: &set.fds_bits) { p in
        p.withMemoryRebound(to: Int32.self, capacity: 32) { $0[offset] |= mask }
    }
}
