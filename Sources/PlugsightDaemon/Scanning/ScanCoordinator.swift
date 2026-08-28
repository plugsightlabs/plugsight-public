// ScanCoordinator.swift  (N8b — Gap A)
//
// Drives API-triggered scans (`scan.start`) through the real ScanOrchestrator,
// asynchronously: the API must return the scanId + `running` immediately (03) and
// the child process runs in the background, driven to a terminal state exactly
// like the mount-triggered path. `scan.cancel` signals the in-flight run's cancel
// token so the process group is killed and the scan ends `canceled`.
//
// The `ScanConfig` for each scan is resolved at scan time via `configForScan`
// (Gap B swaps the hardcoded defaults here for the live policy rows).

import Foundation
import PlugsightCore

final class ScanCoordinator: @unchecked Sendable {

    private let orchestrator: ScanOrchestrator
    private let quarantineDirectory: String
    /// Resolves the config to use for a scan, evaluated fresh at scan time.
    private let configForScan: () -> ScanConfig

    private let lock = NSLock()
    private var tokens: [String: CancelToken] = [:]

    init(orchestrator: ScanOrchestrator,
         quarantineDirectory: String,
         configForScan: @escaping () -> ScanConfig) {
        self.orchestrator = orchestrator
        self.quarantineDirectory = quarantineDirectory
        self.configForScan = configForScan
    }

    /// Open the scan row (returns its id + `running`) and drive the child process
    /// to a terminal state on a background thread. Throws `ScanError`
    /// `scannerUnavailable` (from `begin`) when no engine is present.
    func start(_ request: ScanRequest) throws -> StartedScan {
        let config = configForScan()
        let cancel = CancelToken()
        let started = try orchestrator.begin(request, config: config)   // running row + scan.started
        lock.lock(); tokens[started.scanID] = cancel; lock.unlock()

        Thread.detachNewThread { [orchestrator, started] in
            defer { self.forget(started.scanID) }
            _ = try? orchestrator.run(started, request: request, config: config, cancel: cancel)
        }
        return started
    }

    /// Signal the in-flight run for `scanID` to cancel. Returns false when no run
    /// is in flight (the caller then cancels the row directly).
    @discardableResult
    func cancel(_ scanID: String) -> Bool {
        lock.lock(); let token = tokens[scanID]; lock.unlock()
        token?.cancel()
        return token != nil
    }

    private func forget(_ scanID: String) {
        lock.lock(); tokens[scanID] = nil; lock.unlock()
    }
}
