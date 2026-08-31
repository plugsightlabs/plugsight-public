// ScannerInstallerTests.swift
//
// Deterministic unit tests for ScannerInstaller: the daemon side of the
// one-click ClamAV install the onboarding scanner step offers. The Homebrew
// locator and the process runner are both INJECTED, so these tests never touch
// the network, real brew, or a real install. A "manual" async dispatch lets a
// test observe the idle -> installing -> done/failed transitions step by step.

import Foundation
import XCTest
@testable import PlugsightDaemon

final class ScannerInstallerTests: XCTestCase {

    /// A scriptable runner: returns a queued (exitCode, tail) per invocation and
    /// records the arguments/environment it was called with.
    private final class FakeRunner: InstallProcessRunning, @unchecked Sendable {
        struct Call: Equatable { let executable: String; let arguments: [String]; let env: [String: String] }
        private let lock = NSLock()
        private var results: [InstallRunResult]
        private(set) var calls: [Call] = []
        /// Optional hook invoked at the START of each run (before returning), so a
        /// test can observe the installer's state WHILE a run is "in flight".
        var onRun: (() -> Void)?

        init(results: [InstallRunResult]) { self.results = results }

        func run(executable: String, arguments: [String], environment: [String: String]) -> InstallRunResult {
            lock.lock()
            calls.append(Call(executable: executable, arguments: arguments, env: environment))
            let r = results.isEmpty ? InstallRunResult(exitCode: 0, outputTail: "") : results.removeFirst()
            lock.unlock()
            onRun?()
            return r
        }
    }

    /// An in-memory filesystem: seeded existing paths/contents, and records every
    /// write and mkdir so no real file is touched and a test can assert what the
    /// freshclam bootstrap laid down.
    private final class FakeFileSystem: InstallFileManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: String]
        private var dirs: Set<String>
        private(set) var writes: [(path: String, contents: String)] = []
        private(set) var createdDirs: [String] = []

        init(files: [String: String] = [:], dirs: Set<String> = []) {
            self.files = files; self.dirs = dirs
        }
        func fileExists(atPath path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return files[path] != nil || dirs.contains(path)
        }
        func contents(atPath path: String) -> String? {
            lock.lock(); defer { lock.unlock() }; return files[path]
        }
        @discardableResult
        func write(_ contents: String, toPath path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            files[path] = contents; writes.append((path, contents)); return true
        }
        @discardableResult
        func createDirectory(atPath path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            dirs.insert(path); createdDirs.append(path); return true
        }
    }

    /// A manual async dispatch: captures the work closure instead of running it,
    /// so the test drives it explicitly and can inspect state before/after.
    private final class ManualDispatch: @unchecked Sendable {
        private let lock = NSLock()
        private var work: (() -> Void)?
        func enqueue(_ block: @escaping @Sendable () -> Void) { lock.lock(); work = block; lock.unlock() }
        func runPending() { lock.lock(); let w = work; work = nil; lock.unlock(); w?() }
        var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return work != nil }
    }

    func testInstallFailsWhenHomebrewMissing() {
        let runner = FakeRunner(results: [])
        let installer = ScannerInstaller(
            brewLocator: { nil },
            runner: runner,
            homeDirectory: "/Users/test",
            runAsync: { _ in XCTFail("must not spawn an install when brew is missing") }
        )
        let outcome = installer.startInstall()
        XCTAssertFalse(outcome.accepted)
        XCTAssertEqual(outcome.reason,
            "Homebrew was not found. Install Homebrew from brew.sh, or run the command in Terminal.")
        let snap = installer.snapshot()
        XCTAssertEqual(snap.state, "failed")
        XCTAssertEqual(snap.detail,
            "Homebrew was not found. Install Homebrew from brew.sh, or run the command in Terminal.")
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testInstallTransitionsIdleToInstallingToDone() {
        let dispatch = ManualDispatch()
        let runner = FakeRunner(results: [
            InstallRunResult(exitCode: 0, outputTail: "installed"),   // brew install clamav
            InstallRunResult(exitCode: 0, outputTail: "updated"),     // freshclam
        ])
        // A fresh brew ClamAV: only the .sample exists, no real freshclam.conf.
        let fs = FakeFileSystem(files: [
            "/opt/homebrew/etc/clamav/freshclam.conf.sample":
                "# sample\nExample\nDatabaseMirror database.clamav.net\n",
        ])
        let installer = ScannerInstaller(
            brewLocator: { "/opt/homebrew/bin/brew" },
            runner: runner,
            fileSystem: fs,
            homeDirectory: "/Users/test",
            runAsync: { dispatch.enqueue($0) }
        )

        // Idle before starting.
        XCTAssertEqual(installer.snapshot().state, "idle")
        XCTAssertNil(installer.snapshot().detail)

        // start -> accepted, state installing, work queued but not yet run.
        let outcome = installer.startInstall()
        XCTAssertTrue(outcome.accepted)
        XCTAssertNil(outcome.reason)
        XCTAssertEqual(installer.snapshot().state, "installing")
        XCTAssertEqual(installer.snapshot().detail, "Installing ClamAV...")
        XCTAssertTrue(dispatch.hasPending)

        // Run the background work -> success -> done.
        dispatch.runPending()
        XCTAssertEqual(installer.snapshot().state, "done")

        // It ran brew install clamav, then freshclam, with the noninteractive env.
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[0].executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(runner.calls[0].arguments, ["install", "clamav"])
        XCTAssertEqual(runner.calls[0].env["HOME"], "/Users/test")
        XCTAssertEqual(runner.calls[0].env["NONINTERACTIVE"], "1")
        XCTAssertTrue(runner.calls[0].env["PATH"]?.contains("/opt/homebrew/bin") == true)
        XCTAssertTrue(runner.calls[1].executable.hasSuffix("/freshclam"))
        // freshclam is pointed at the bootstrapped config (fresh brew ClamAV omits
        // a real freshclam.conf), not run bare.
        XCTAssertEqual(runner.calls[1].arguments,
                       ["--config-file=/opt/homebrew/etc/clamav/freshclam.conf"])
        // The bootstrap materialized freshclam.conf from the sample with the
        // Example line commented, and ensured the database dir exists.
        let written = fs.writes.first { $0.path == "/opt/homebrew/etc/clamav/freshclam.conf" }
        XCTAssertNotNil(written, "a real freshclam.conf must be written from the sample")
        XCTAssertFalse(written?.contents.contains("\nExample\n") == true,
                       "the Example directive must be commented so freshclam runs")
        XCTAssertTrue(written?.contents.contains("#Example") == true)
        XCTAssertTrue(fs.createdDirs.contains("/opt/homebrew/var/lib/clamav"))
    }

    func testFreshclamConfigIsNotClobberedWhenAlreadyPresent() {
        let dispatch = ManualDispatch()
        let runner = FakeRunner(results: [
            InstallRunResult(exitCode: 0, outputTail: "installed"),
            InstallRunResult(exitCode: 0, outputTail: "updated"),
        ])
        // A user who already has a real freshclam.conf: it must be left untouched.
        let fs = FakeFileSystem(files: [
            "/opt/homebrew/etc/clamav/freshclam.conf": "DatabaseMirror mymirror.example\n",
        ], dirs: ["/opt/homebrew/var/lib/clamav"])
        let installer = ScannerInstaller(
            brewLocator: { "/opt/homebrew/bin/brew" },
            runner: runner,
            fileSystem: fs,
            homeDirectory: "/Users/test",
            runAsync: { dispatch.enqueue($0) }
        )
        XCTAssertTrue(installer.startInstall().accepted)
        dispatch.runPending()
        XCTAssertEqual(installer.snapshot().state, "done")
        // No write to the existing config, and no dir re-creation.
        XCTAssertTrue(fs.writes.isEmpty, "an existing freshclam.conf must not be clobbered")
        XCTAssertTrue(fs.createdDirs.isEmpty, "an existing database dir must not be recreated")
        XCTAssertEqual(runner.calls[1].arguments,
                       ["--config-file=/opt/homebrew/etc/clamav/freshclam.conf"])
    }

    func testFreshclamConfigWrittenMinimalWhenNoSample() {
        let dispatch = ManualDispatch()
        let runner = FakeRunner(results: [
            InstallRunResult(exitCode: 0, outputTail: "installed"),
            InstallRunResult(exitCode: 0, outputTail: "updated"),
        ])
        // Intel prefix, and neither a real config nor a sample exists.
        let fs = FakeFileSystem()
        let installer = ScannerInstaller(
            brewLocator: { "/usr/local/bin/brew" },
            runner: runner,
            fileSystem: fs,
            homeDirectory: "/Users/test",
            runAsync: { dispatch.enqueue($0) }
        )
        XCTAssertTrue(installer.startInstall().accepted)
        dispatch.runPending()
        XCTAssertEqual(installer.snapshot().state, "done")
        let written = fs.writes.first { $0.path == "/usr/local/etc/clamav/freshclam.conf" }
        XCTAssertNotNil(written, "a minimal freshclam.conf must be written when no sample exists")
        XCTAssertTrue(written?.contents.contains("DatabaseDirectory /usr/local/var/lib/clamav") == true)
        XCTAssertTrue(written?.contents.contains("DatabaseMirror database.clamav.net") == true)
        // Intel prefix resolved from the brew path, not hardcoded to /opt/homebrew.
        XCTAssertEqual(runner.calls[1].arguments,
                       ["--config-file=/usr/local/etc/clamav/freshclam.conf"])
        XCTAssertTrue(fs.createdDirs.contains("/usr/local/var/lib/clamav"))
    }

    func testBrewPrefixResolvesFromBrewPath() {
        XCTAssertEqual(ScannerInstaller.brewPrefix(fromBrewPath: "/opt/homebrew/bin/brew"), "/opt/homebrew")
        XCTAssertEqual(ScannerInstaller.brewPrefix(fromBrewPath: "/usr/local/bin/brew"), "/usr/local")
    }

    func testInstallFailsOnNonZeroExitWithDetail() {
        let dispatch = ManualDispatch()
        let runner = FakeRunner(results: [
            InstallRunResult(exitCode: 1, outputTail: "Error: clamav: no bottle available"),
        ])
        let installer = ScannerInstaller(
            brewLocator: { "/opt/homebrew/bin/brew" },
            runner: runner,
            homeDirectory: "/Users/test",
            runAsync: { dispatch.enqueue($0) }
        )
        XCTAssertTrue(installer.startInstall().accepted)
        dispatch.runPending()
        let snap = installer.snapshot()
        XCTAssertEqual(snap.state, "failed")
        XCTAssertNotNil(snap.detail)
        XCTAssertTrue(snap.detail?.contains("no bottle available") == true,
                      "the failure detail carries the error tail; got \(snap.detail ?? "nil")")
        XCTAssertTrue(snap.detail?.contains("Terminal") == true,
                      "the failure detail carries the Terminal-fallback hint")
        // freshclam never runs when brew install failed.
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testConcurrentInstallReturnsAlreadyRunning() {
        let dispatch = ManualDispatch()
        let runner = FakeRunner(results: [
            InstallRunResult(exitCode: 0, outputTail: ""),
            InstallRunResult(exitCode: 0, outputTail: ""),
        ])
        let installer = ScannerInstaller(
            brewLocator: { "/opt/homebrew/bin/brew" },
            runner: runner,
            fileSystem: FakeFileSystem(dirs: ["/opt/homebrew/var/lib/clamav"]),
            homeDirectory: "/Users/test",
            runAsync: { dispatch.enqueue($0) }
        )
        // First start puts it in installing (work still pending).
        XCTAssertTrue(installer.startInstall().accepted)
        XCTAssertEqual(installer.snapshot().state, "installing")

        // Second start while installing is rejected.
        let second = installer.startInstall()
        XCTAssertFalse(second.accepted)
        XCTAssertEqual(second.reason, "An install is already running.")

        // Finishing the first lets a later install run again.
        dispatch.runPending()
        XCTAssertEqual(installer.snapshot().state, "done")
        XCTAssertTrue(installer.startInstall().accepted)
    }

    func testDefaultBrewLocatorResolvesInjectedExistenceProbe() {
        // The locator prefers Apple Silicon then Intel; injecting the existence
        // probe keeps this deterministic on any host.
        let armOnly = ScannerInstaller.brewPath { $0 == "/opt/homebrew/bin/brew" }
        XCTAssertEqual(armOnly, "/opt/homebrew/bin/brew")
        let intelOnly = ScannerInstaller.brewPath { $0 == "/usr/local/bin/brew" }
        XCTAssertEqual(intelOnly, "/usr/local/bin/brew")
        let neither = ScannerInstaller.brewPath { _ in false }
        XCTAssertNil(neither)
    }
}
