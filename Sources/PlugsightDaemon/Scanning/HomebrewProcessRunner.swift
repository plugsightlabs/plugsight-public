// HomebrewProcessRunner.swift
//
// The real InstallProcessRunning used by ScannerInstaller. It mirrors
// ScanProcessRunner's posix_spawn pattern (own process group, drained pipes,
// background reap) but adds a CUSTOM child environment (brew/freshclam need
// HOME, a PATH that includes the brew prefix, and NONINTERACTIVE=1 so brew never
// prompts) and merges stdout/stderr into one output blob for the install detail.
//
// A generous timeout bounds a hung install (the whole process group is killed),
// so a wedged brew can never leak the background install thread forever.

import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public final class HomebrewProcessRunner: InstallProcessRunning {

    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    /// - Parameters:
    ///   - timeout: hard cap on one command (default 20 minutes; a large brew
    ///     download plus compile can be slow, but must not hang forever).
    ///   - pollInterval: how often the wait loop wakes to enforce the timeout.
    public init(timeout: TimeInterval = 20 * 60, pollInterval: TimeInterval = 0.05) {
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func run(executable: String, arguments: [String], environment: [String: String]) -> InstallRunResult {
        var outPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else {
            return InstallRunResult(exitCode: 127, outputTail: "pipe() failed")
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        // Merge stdout AND stderr onto the one pipe write end.
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Own process group so a timeout kill takes any helpers with it.
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        let argv = [executable] + arguments
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgv where p != nil { free(p) } }

        // Build the child envp from the supplied environment (KEY=VALUE strings).
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { for p in cEnv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = executable.withCString { path in
            posix_spawn(&pid, path, &fileActions, &attr, cArgv, cEnv)
        }

        // Parent no longer needs the child's write end.
        close(outPipe[1])

        guard rc == 0 else {
            close(outPipe[0])
            return InstallRunResult(exitCode: 127,
                                    outputTail: "posix_spawn failed: \(String(cString: strerror(rc)))")
        }

        // Drain the merged output on a background thread (avoid pipe deadlock).
        let ioGroup = DispatchGroup()
        var outData = Data()
        let outHandle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        ioGroup.enter()
        DispatchQueue.global().async { outData = outHandle.readDataToEndOfFile(); ioGroup.leave() }

        // Reap on a background thread; signal when done.
        let reaped = DispatchSemaphore(value: 0)
        let statusLock = NSLock()
        var rawStatus: Int32 = 0
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR { /* retry */ }
            statusLock.lock(); rawStatus = status; statusLock.unlock()
            reaped.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var exitCode: Int32 = 0
        while true {
            if reaped.wait(timeout: .now() + pollInterval) == .success {
                statusLock.lock(); let status = rawStatus; statusLock.unlock()
                exitCode = Self.exitCode(fromWaitStatus: status)
                break
            }
            if Date() >= deadline {
                killpg(pid, SIGKILL)
                reaped.wait()
                exitCode = 124   // conventional timeout code
                break
            }
        }

        ioGroup.wait()
        return InstallRunResult(exitCode: exitCode, outputTail: String(decoding: outData, as: UTF8.self))
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let lowByte = status & 0x7f
        if lowByte == 0 { return (status >> 8) & 0xff }
        return 128 + lowByte   // died by signal: never reads as success (0)
    }
}
