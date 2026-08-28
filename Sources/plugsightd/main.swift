// plugsightd entry point (N8). Deliberately THIN: parse boot options, probe
// capabilities, build the sources, hand everything to `DaemonCore`, and wait
// for a signal. All wiring logic lives in DaemonCore (testable); all detection
// logic lives in PlugsightCore.
//
// Dev/CI flags (N8-G, consumed by N9's test:roundtrip):
//   PLUGSIGHT_SEED_DB=<db path>  (or --seed <db path>)   boot against a seeded
//     database, with NO hardware sources attached.
//   PLUGSIGHT_STATE_DIR=<dir>    (or --socket <dir | .../plugsightd.sock>)
//     where the socket + token live.

import Foundation
import PlugsightCore
import PlugsightDaemon

#if canImport(CoreGraphics)
import CoreGraphics
#endif

let daemonVersion = "0.1.0"

// MARK: - Dev flag: --print-catalog (N14 drift gate)
//
// Print the CLOSED SET of event kinds this daemon emits (the canonical 06
// catalog, defined once in `EventKindCatalog`) as deterministic JSON, then exit.
// This must NOT boot the daemon (no store, no sources, no socket): it is a pure
// read of a compile-time constant so CI's drift gate can call it cheaply.
if CommandLine.arguments.contains("--print-catalog") {
    print(EventKindCatalog.printableJSON())
    exit(0)
}

let options = DaemonBootOptions.parse(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment
)

// State directory (socket + token live here, 0700).
try FileManager.default.createDirectory(
    atPath: options.stateDirectory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
)

let store = try EventStore(path: options.databasePath)

// MARK: - Capability probes (D)

// Input Monitoring: preflight only — never prompts. The app (N10) owns the
// grant flow; the daemon just reports the truth.
#if canImport(CoreGraphics)
let inputMonitoring = CGPreflightListenEventAccess()
#else
let inputMonitoring = false
#endif

// ClamAV: resolved the same way the orchestrator resolves it.
let discovery = EngineDiscovery(
    clamdSocketLive: { FileManager.default.fileExists(atPath: $0) }
)
let clamavAvailable: Bool
switch discovery.resolve() {
case .unavailable: clamavAvailable = false
default: clamavAvailable = true
}

// Endpoint Security: the extension ships with the app (N10/N11); this
// standalone daemon reports it inactive until the app activates it.
let capabilities = Capabilities(
    inputMonitoring: inputMonitoring,
    endpointSecurity: false,
    clamav: clamavAvailable
)

// MARK: - Sources + scanning

// Seeded boots attach NO hardware sources: the daemon serves the seeded state
// over the socket for round-trip tests.
let source: DeviceEventSource = options.seeded
    ? CompositeDeviceEventSource(sources: [])
    : CompositeDeviceEventSource(sources: [
        IOKitDeviceSource(),
        HIDTimingSource(),
        DiskArbitrationSource(),
    ])

let quarantineDirectory = (options.stateDirectory as NSString)
    .appendingPathComponent("quarantine")
let orchestrator = ScanOrchestrator(
    store: store,
    discovery: discovery,
    runner: ScanProcessRunner(),
    definitions: DefinitionsAge(databaseDirectory: "/opt/homebrew/var/lib/clamav")
)
// The base is the v1 policy DEFAULTS; the daemon overlays the LIVE policy rows on
// top at scan time (ScanConfigResolver), so a `policy.set` takes effect for
// subsequent scans (N8b Gap B) on both the mount and API paths.
let scanConfig = ScanConfig.defaults(quarantineDirectory: quarantineDirectory)

// MARK: - Boot

let daemon = DaemonCore(
    store: store,
    source: source,
    stateDirectory: options.stateDirectory,
    daemonVersion: daemonVersion,
    capabilities: capabilities,
    quarantineDirectory: quarantineDirectory,
    scanOrchestrator: orchestrator,
    scanConfig: scanConfig
)

try daemon.start()
daemon.startEventFlow()

// No secrets in logs: the token itself never appears here — only its path.
print("plugsightd \(daemonVersion) up — socket \(daemon.server.socketPath)")
print("plugsightd: database \(options.databasePath)\(options.seeded ? " (seeded)" : "")")
print("plugsightd: token file \(daemon.server.tokenPath)")

// MARK: - Clean shutdown on SIGINT/SIGTERM (daemon.stopped, L10)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let shutdown: () -> Void = {
    daemon.stop()
    exit(0)
}
sigintSource.setEventHandler(handler: shutdown)
sigtermSource.setEventHandler(handler: shutdown)
sigintSource.resume()
sigtermSource.resume()

dispatchMain()
