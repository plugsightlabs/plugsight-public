// ScanProcessRunner.swift
//
// Run a scan as a child process with a hard timeout and cooperative cancellation
// (docs/spec/05). Two requirements shape the implementation:
//
//   1. Timeout and cancel must kill the WHOLE process group, not just the direct
//      child. clamscan/clamdscan can spawn helpers; killing only the front-end
//      would orphan them. So the child is spawned as its OWN process-group leader
//      (posix_spawn with POSIX_SPAWN_SETPGROUP, pgroup 0) and we `killpg` it.
//      This is done atomically at spawn — the parent-side setpgid race (the child
//      may already have exec'd) would otherwise leave the child in our group,
//      where killpg would be a no-op or, worse, target us.
//
//   2. Exit codes are the verdict authority: 0 clean, 1 findings, 2 engine error.
//      The runner reports them verbatim as `.exited(code:)`; mapping to a scan
//      state is ScanOutputParser's job.

import Foundation

/// A one-shot cancellation flag, safe to set from any thread.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    public init() {}
    public func cancel() { lock.lock(); canceled = true; lock.unlock() }
    public var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
}

/// Captured result of a run.
public struct RunResult: Equatable, Sendable {
    public let outcome: RunOutcome
    public let stdout: String
    public let stderr: String

    public init(outcome: RunOutcome, stdout: String, stderr: String) {
        self.outcome = outcome
        self.stdout = stdout
        self.stderr = stderr
    }
}

public final class ScanProcessRunner {

    private let pollInterval: TimeInterval

    /// - Parameter pollInterval: how often the wait loop wakes to re-check the
    ///   timeout and the cancel flag. Small enough to be responsive, large enough
    ///   to be cheap.
    public init(pollInterval: TimeInterval = 0.02) {
        self.pollInterval = pollInterval
    }

    /// Run `executable` with `arguments`, giving it at most `timeout` seconds.
    /// Returns the outcome and captured stdout/stderr. Never throws: a launch
    /// failure is reported as a non-zero exit.
    public func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        cancel: CancelToken? = nil
    ) -> RunResult {
        // Pipes: [0] read end (parent), [1] write end (child).
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return RunResult(outcome: .exited(code: 127), stdout: "", stderr: "pipe() failed")
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1) // child stdout -> pipe
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2) // child stderr -> pipe
        // Close the inherited pipe fds in the child; the dup2'd 1/2 remain.
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // pgroup 0 -> the child becomes the leader of a NEW group (pgid == pid).
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        let argv = [executable] + arguments
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = executable.withCString { path in
            posix_spawn(&pid, path, &fileActions, &attr, cArgv, environ)
        }

        // Parent no longer needs the child's write ends.
        close(outPipe[1])
        close(errPipe[1])

        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return RunResult(outcome: .exited(code: 127),
                             stdout: "", stderr: "posix_spawn failed: \(String(cString: strerror(rc)))")
        }

        // Drain stdout/stderr on background threads to avoid pipe-buffer deadlock.
        let ioGroup = DispatchGroup()
        let ioQueue = DispatchQueue(label: "plugsight.scan.io", attributes: .concurrent)
        var outData = Data()
        var errData = Data()
        let outHandle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
        ioGroup.enter(); ioQueue.async { outData = outHandle.readDataToEndOfFile(); ioGroup.leave() }
        ioGroup.enter(); ioQueue.async { errData = errHandle.readDataToEndOfFile(); ioGroup.leave() }

        // Reap the child on a background thread; signal the semaphore when done.
        let reaped = DispatchSemaphore(value: 0)
        let statusLock = NSLock()
        var rawStatus: Int32 = 0
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR { /* retry */ }
            statusLock.lock(); rawStatus = status; statusLock.unlock()
            reaped.signal()
        }

        // Wait loop: poll for natural exit, else enforce timeout / cancel by
        // killing the whole process group.
        let deadline = Date().addingTimeInterval(timeout)
        var outcome: RunOutcome
        while true {
            if reaped.wait(timeout: .now() + pollInterval) == .success {
                statusLock.lock(); let status = rawStatus; statusLock.unlock()
                outcome = Self.outcome(fromWaitStatus: status)
                break
            }
            if cancel?.isCanceled == true {
                killpg(pid, SIGKILL)
                reaped.wait()
                outcome = .canceled
                break
            }
            if Date() >= deadline {
                killpg(pid, SIGKILL)
                reaped.wait()
                outcome = .timedOut
                break
            }
        }

        ioGroup.wait()
        return RunResult(
            outcome: outcome,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Translate a `waitpid` status into an outcome. A normal exit carries its
    /// code; death by signal (shouldn't happen on the natural path) is surfaced
    /// as a non-zero code so it never reads as clean.
    private static func outcome(fromWaitStatus status: Int32) -> RunOutcome {
        // WIFEXITED / WEXITSTATUS without the C macros (not imported into Swift).
        let lowByte = status & 0x7f
        if lowByte == 0 {
            let code = (status >> 8) & 0xff
            return .exited(code: code)
        }
        // Terminated by a signal: not a clean exit.
        return .exited(code: 128 + lowByte)
    }
}
