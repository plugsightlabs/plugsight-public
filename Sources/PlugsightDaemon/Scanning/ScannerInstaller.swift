// ScannerInstaller.swift
//
// The daemon side of the one-click ClamAV install the onboarding scanner step
// offers (owner-approved). Plugsight ships no malware database; it drives ClamAV
// when installed. This performs `brew install clamav` followed by `freshclam` on
// a BACKGROUND thread so the API/analyzer loop is never blocked, and exposes a
// small thread-safe state snapshot (installState/installDetail) that status.get
// reads on the API thread while the install thread writes it.
//
// Plugsight stays a DETECTOR, not a blocker: this install is user-initiated (the
// app calls scanner.install only when the user opts in) and touches nothing on
// the mount path.
//
// Both collaborators are INJECTABLE so tests are deterministic and never touch
// the network or a real brew:
//   - `brewLocator` resolves the brew executable (Apple Silicon then Intel).
//   - `runner` spawns a child process and reports its exit code + output tail.
//   - `runAsync` schedules the background work (tests capture it and run it by
//     hand to observe the idle -> installing -> done/failed transitions).

import Foundation

/// The captured result of one install child process.
public struct InstallRunResult: Equatable, Sendable {
    /// 0 on success; non-zero is a failure whose `outputTail` explains why.
    public let exitCode: Int32
    /// The tail of the combined stdout/stderr, used as the human-readable detail.
    public let outputTail: String

    public init(exitCode: Int32, outputTail: String) {
        self.exitCode = exitCode
        self.outputTail = outputTail
    }
}

/// The process-spawn seam. The real implementation is `HomebrewProcessRunner`;
/// tests inject a fake so no real command ever runs.
public protocol InstallProcessRunning: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String]) -> InstallRunResult
}

/// The filesystem seam for the freshclam config bootstrap. A fresh Homebrew
/// ClamAV lays down only `freshclam.conf.sample` (with an `Example` line that
/// makes freshclam refuse to run), so the installer must materialize a real
/// `freshclam.conf` and the database dir before running freshclam. The real
/// implementation is `RealInstallFileSystem` (FileManager); tests inject a fake
/// so no real file or directory is ever touched.
public protocol InstallFileManaging: Sendable {
    func fileExists(atPath path: String) -> Bool
    /// The file's contents, or nil when it is absent/unreadable.
    func contents(atPath path: String) -> String?
    /// Create the file (and its parent dirs); returns false on failure.
    @discardableResult
    func write(_ contents: String, toPath path: String) -> Bool
    /// Create the directory (and parents); returns false on failure. A no-op that
    /// still returns true when it already exists.
    @discardableResult
    func createDirectory(atPath path: String) -> Bool
}

/// The real filesystem, backing the freshclam config bootstrap on device.
public struct RealInstallFileSystem: InstallFileManaging {
    public init() {}
    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
    public func contents(atPath path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
    @discardableResult
    public func write(_ contents: String, toPath path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        return (try? contents.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
    @discardableResult
    public func createDirectory(atPath path: String) -> Bool {
        (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil
    }
}

public final class ScannerInstaller: @unchecked Sendable {

    /// The Homebrew-missing message, shown when neither brew prefix exists. It is
    /// both the `scanner.install` rejection reason and the failed-state detail.
    /// (No em dashes: shipped user-facing string.)
    public static let homebrewMissingMessage =
        "Homebrew was not found. Install Homebrew from brew.sh, or run the command in Terminal."

    /// The Terminal-fallback hint appended to a failure detail so the user always
    /// has a next step (Settings shows a "run it in Terminal" button on failure).
    public static let terminalFallbackHint =
        "You can also install it yourself: run brew install clamav in Terminal, then freshclam."

    private enum State: String { case idle, installing, failed, done }

    private let lock = NSLock()
    private var state: State = .idle
    private var detail: String?

    private let brewLocator: @Sendable () -> String?
    private let runner: InstallProcessRunning
    private let fileSystem: InstallFileManaging
    private let homeDirectory: String
    private let runAsync: (@escaping @Sendable () -> Void) -> Void

    /// - Parameters:
    ///   - brewLocator: resolves the brew executable, or nil when Homebrew is
    ///     absent. Defaults to the real Apple-Silicon-then-Intel probe.
    ///   - runner: spawns the child processes. Defaults to the real posix_spawn
    ///     runner; tests inject a fake.
    ///   - homeDirectory: the child `HOME` (brew and freshclam need it).
    ///   - runAsync: schedules the blocking install off the caller's thread.
    ///     Defaults to a detached thread; tests capture and drive it.
    public init(
        brewLocator: @escaping @Sendable () -> String? = { ScannerInstaller.brewPath() },
        runner: InstallProcessRunning = HomebrewProcessRunner(),
        fileSystem: InstallFileManaging = RealInstallFileSystem(),
        homeDirectory: String = NSHomeDirectory(),
        runAsync: @escaping (@escaping @Sendable () -> Void) -> Void = { work in Thread.detachNewThread(work) }
    ) {
        self.brewLocator = brewLocator
        self.runner = runner
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
        self.runAsync = runAsync
    }

    /// The current install progress for status.get. `state` is one of
    /// idle/installing/failed/done; `detail` is the latest progress line or the
    /// error tail on failure (nil when idle).
    public func snapshot() -> (state: String, detail: String?) {
        lock.lock(); defer { lock.unlock() }
        return (state.rawValue, detail)
    }

    /// Start an install if none is running and Homebrew is present.
    /// - Returns: `(accepted: true, reason: nil)` when an install was started;
    ///   `(accepted: false, reason: <message>)` when it cannot start (an install
    ///   is already running, or Homebrew is not found).
    public func startInstall() -> (accepted: Bool, reason: String?) {
        lock.lock()
        if state == .installing {
            lock.unlock()
            return (false, "An install is already running.")
        }
        guard let brew = brewLocator() else {
            state = .failed
            detail = Self.homebrewMissingMessage
            lock.unlock()
            return (false, Self.homebrewMissingMessage)
        }
        state = .installing
        detail = "Installing ClamAV..."
        lock.unlock()

        let home = homeDirectory
        runAsync { [self] in
            perform(brew: brew, home: home)
        }
        return (true, nil)
    }

    // MARK: - Background work

    private func perform(brew: String, home: String) {
        let brewBin = (brew as NSString).deletingLastPathComponent   // e.g. /opt/homebrew/bin
        let prefix = Self.brewPrefix(fromBrewPath: brew)             // e.g. /opt/homebrew
        let env = [
            "HOME": home,
            // brew must find its own tools; keep the system dirs too.
            "PATH": brewBin + ":/usr/bin:/bin:/usr/sbin:/sbin",
            // Never prompt: this runs headless on a background thread.
            "NONINTERACTIVE": "1",
        ]

        // 1. brew install clamav
        let install = runner.run(executable: brew, arguments: ["install", "clamav"], environment: env)
        guard install.exitCode == 0 else {
            fail(tail: install.outputTail)
            return
        }

        // 2. Bootstrap the freshclam config a fresh brew ClamAV omits. Without a
        //    real freshclam.conf (brew ships only the .sample, whose `Example`
        //    line makes freshclam refuse to run) and a writable database dir,
        //    freshclam exits non-zero on every clean install. Idempotent: an
        //    existing real config is never clobbered.
        let configPath = Self.ensureFreshclamConfig(prefix: prefix, fileSystem: fileSystem)

        // 3. freshclam (download the signature definitions), pointed at that config.
        setDetail("Downloading virus definitions...")
        let freshclam = brewBin + "/freshclam"
        let fresh = runner.run(executable: freshclam,
                               arguments: ["--config-file=" + configPath],
                               environment: env)
        guard fresh.exitCode == 0 else {
            fail(tail: fresh.outputTail)
            return
        }

        // Success: availability is re-resolved lazily by status.get's clamav
        // resolver (it re-runs EngineDiscovery per call), so nothing to poll here.
        lock.lock()
        state = .done
        detail = "ClamAV installed."
        lock.unlock()
    }

    private func fail(tail: String) {
        let trimmed = Self.tail(of: tail)
        let message = trimmed.isEmpty
            ? "The install did not finish. \(Self.terminalFallbackHint)"
            : "\(trimmed) \(Self.terminalFallbackHint)"
        lock.lock()
        state = .failed
        detail = message
        lock.unlock()
    }

    private func setDetail(_ line: String) {
        lock.lock(); detail = line; lock.unlock()
    }

    /// Keep only the last ~600 characters of an output blob so a failure detail
    /// stays a readable tail rather than a wall of log.
    private static func tail(of output: String, max: Int = 600) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return "..." + String(trimmed.suffix(max))
    }

    // MARK: - freshclam config bootstrap

    /// Ensure `<prefix>/etc/clamav/freshclam.conf` and the database dir exist so
    /// freshclam can run on a fresh brew ClamAV, and return the config path.
    ///
    /// - A real, pre-existing `freshclam.conf` is left untouched (idempotent).
    /// - Otherwise, if `freshclam.conf.sample` exists, it is copied with any
    ///   `Example` directive commented out (freshclam refuses to run while an
    ///   `Example` line is present).
    /// - If no sample exists either, a minimal valid config is written.
    /// The database dir (`<prefix>/var/lib/clamav`) is created when missing so
    /// freshclam has somewhere to write the definitions.
    static func ensureFreshclamConfig(prefix: String, fileSystem: InstallFileManaging) -> String {
        let etcDir = prefix + "/etc/clamav"
        let configPath = etcDir + "/freshclam.conf"
        let samplePath = configPath + ".sample"
        let dbDir = prefix + "/var/lib/clamav"

        if !fileSystem.fileExists(atPath: configPath) {
            if let sample = fileSystem.contents(atPath: samplePath) {
                fileSystem.write(commentingExample(in: sample), toPath: configPath)
            } else {
                let minimal = "DatabaseDirectory \(dbDir)\nDatabaseMirror database.clamav.net\n"
                fileSystem.write(minimal, toPath: configPath)
            }
        }

        if !fileSystem.fileExists(atPath: dbDir) {
            fileSystem.createDirectory(atPath: dbDir)
        }
        return configPath
    }

    /// Comment out any line whose first token is `Example` so freshclam stops
    /// refusing to run. (`freshclam.conf.sample` ships exactly one such line.)
    static func commentingExample(in config: String) -> String {
        let lines = config.components(separatedBy: "\n").map { line -> String in
            line.trimmingCharacters(in: .whitespaces) == "Example" ? "#" + line : line
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Brew location

    /// Resolve the brew executable: Apple Silicon (`/opt/homebrew/bin/brew`)
    /// first, then Intel (`/usr/local/bin/brew`). The existence probe is injected
    /// so tests stay deterministic on any host.
    public static func brewPath(
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if exists(candidate) { return candidate }
        }
        return nil
    }

    /// The Homebrew prefix for a located brew executable: `/opt/homebrew/bin/brew`
    /// -> `/opt/homebrew`, `/usr/local/bin/brew` -> `/usr/local`. Derived from the
    /// path (strip `/bin/brew`) rather than string-matched, so it holds for any
    /// prefix.
    public static func brewPrefix(fromBrewPath brew: String) -> String {
        let bin = (brew as NSString).deletingLastPathComponent          // <prefix>/bin
        return (bin as NSString).deletingLastPathComponent              // <prefix>
    }
}
