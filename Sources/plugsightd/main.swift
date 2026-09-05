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
import PlugsightESCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// The compiled fallback version, stamped by ops/sync-versions.mjs and checked
// by ops/release.mjs. A daemon running from inside an app bundle reports the
// BUNDLE's CFBundleShortVersionString instead (Bundle.main resolves the
// enclosing .app for Contents/MacOS/plugsightd), so a dev bundle honestly says
// 0.0.0-dev and a release says its shipped version — one build-time source,
// never a stale constant on screen. A bare `swift run` binary has no bundle
// version and uses the constant.
let daemonVersion = "1.1.0"
let effectiveDaemonVersion =
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? daemonVersion

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
// grant flow; the daemon just reports the truth. The resolver re-runs the
// cheap preflight on every status.get, so a grant made while the daemon runs
// registers without a restart (the HID sensor itself still opens only at
// boot; status.get's inputMonitoringSensor reports that honestly).
#if canImport(CoreGraphics)
let inputMonitoringResolver: @Sendable () -> Bool = { CGPreflightListenEventAccess() }
#else
let inputMonitoringResolver: @Sendable () -> Bool = { false }
#endif
let inputMonitoring = inputMonitoringResolver()

// ClamAV: resolved the same way the orchestrator resolves it. The resolver
// closure re-runs discovery so status.get stays fresh (a scanner installed
// while the daemon runs is seen without a restart) and returns the resolved
// engine's NAME (nil = unavailable) so status.get reports clamscan-only hosts
// honestly; the boot value below only seeds the hello capabilities snapshot.
let discovery = EngineDiscovery(
    clamdSocketLive: { FileManager.default.fileExists(atPath: $0) }
)
let clamavResolver: @Sendable () -> String? = {
    switch EngineDiscovery(
        clamdSocketLive: { FileManager.default.fileExists(atPath: $0) }
    ).resolve() {
    case .clamdscan: return "clamdscan"
    case .clamscan: return "clamscan"
    case .unavailable: return nil
    }
}
let clamavAvailable = clamavResolver() != nil

// Endpoint Security: the boot flag stays false — status.get reports "active"
// ONLY through the live-handshake resolver below (esClient.handshakeActive),
// which is true solely while the ES extension acknowledged a recent policy
// push. Until the entitlement lands and the app activates the extension, the
// handshake can never go live and status honestly says inactive.
let capabilities = Capabilities(
    inputMonitoring: inputMonitoring,
    endpointSecurity: false,
    clamav: clamavAvailable
)

// MARK: - Endpoint Security link (Wave 4: the hold path)
//
// Dialing the extension's Mach service is safe when the extension is absent
// (the normal state until the Apple ES entitlement is granted): the
// connection just invalidates and the client redials in the background.
let esClient = ESExtensionXPCClient(
    endpoint: .machService(name: ESDefaults.machServiceName),
    peerRequirement: ESPeerRequirement(
        teamID: PlugsightIdentifiers.teamID,
        bundleIDPrefix: PlugsightIdentifiers.bundleIDPrefix
    ).codeSigningRequirementString(exactBundleID: PlugsightIdentifiers.esExtensionBundleID)
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
// One DefinitionsAge over the freshclam database dir feeds both the scan records
// (via the orchestrator) and status.get's real definitionsAgeDays.
// Resolve the ClamAV database dir under the actual Homebrew prefix (Apple Silicon
// then Intel), so definitionsAgeDays is populated on Intel Macs too rather than
// always nil from a hardcoded /opt/homebrew path. Falls back to the Apple Silicon
// default when brew is not found.
let clamavDatabaseDirectory: String = {
    if let brew = ScannerInstaller.brewPath() {
        return ScannerInstaller.brewPrefix(fromBrewPath: brew) + "/var/lib/clamav"
    }
    return "/opt/homebrew/var/lib/clamav"
}()
let definitions = DefinitionsAge(databaseDirectory: clamavDatabaseDirectory)
let definitionsAgeResolver: @Sendable () -> Int? = { definitions.ageInDays() }
let orchestrator = ScanOrchestrator(
    store: store,
    discovery: discovery,
    runner: ScanProcessRunner(),
    definitions: definitions
)
// The one-click ClamAV installer the onboarding scanner step drives via
// scanner.install; it runs brew install clamav + freshclam on a background
// thread and exposes progress through status.get's installState/installDetail.
let scannerInstaller = ScannerInstaller()
// The base is the v1 policy DEFAULTS; the daemon overlays the LIVE policy rows on
// top at scan time (ScanConfigResolver), so a `policy.set` takes effect for
// subsequent scans (N8b Gap B) on both the mount and API paths.
let scanConfig = ScanConfig.defaults(quarantineDirectory: quarantineDirectory)

// MARK: - Boot

let daemon = DaemonCore(
    store: store,
    source: source,
    stateDirectory: options.stateDirectory,
    daemonVersion: effectiveDaemonVersion,
    capabilities: capabilities,
    quarantineDirectory: quarantineDirectory,
    scanOrchestrator: orchestrator,
    scanConfig: scanConfig,
    clamavResolver: clamavResolver,
    definitionsAgeResolver: definitionsAgeResolver,
    scannerInstaller: scannerInstaller,
    inputMonitoringResolver: inputMonitoringResolver,
    // Truthful endpoint-security status (unit 5): active only on a live,
    // acknowledged XPC handshake with the extension.
    esActiveResolver: { esClient.handshakeActive }
)

// MARK: - ES hold-path wiring (policy pusher + hold coordinator)

let esAPIStore = APIStore(store: store)

let esPusher = ESPolicyPusher(
    // Live policy `holdUntilScanned`, defaulting like every other policy read.
    holdPolicyProvider: {
        ESPolicyReads.holdUntilScanned(from: (try? esAPIStore.policyRaw()) ?? [:])
    },
    trustProvider: {
        let raw = (try? esAPIStore.trustTiersByIdentityKey()) ?? [:]
        var out: [String: TrustTier] = [:]
        for (key, tier) in raw { out[key] = TrustTier(rawValue: tier) ?? TrustTier.none }
        return out
    },
    identityResolver: { [weak daemon] in daemon?.identityKey(forCollectorDeviceKey: $0) },
    send: { esClient.push($0) }
)

let holdCoordinator = MountHoldCoordinator(
    store: store,
    remounter: DiskArbitrationRemounter(
        privateMountRoot: (options.stateDirectory as NSString).appendingPathComponent("holdscan")
    ),
    // The EXISTING scan pipeline, with the config resolved from the live
    // policy rows at scan time (mirrors the mount path).
    runScan: { request in
        let liveConfig = ESPolicyReads.liveScanConfig(
            base: scanConfig, from: (try? esAPIStore.policyRaw()) ?? [:]
        )
        return try orchestrator.scan(request, config: liveConfig).state
    },
    deviceForBSD: { bsdName in
        guard let identity = esPusher.currentSnapshot().deviceKey(forBSDName: bsdName) else {
            return nil
        }
        let deviceID = (try? esAPIStore.deviceID(forIdentityKey: identity)) ?? nil
        return MountHoldCoordinator.DeviceRef(identityKey: identity, deviceID: deviceID)
    },
    markCleared: { esPusher.markCleared(identityKey: $0) }
)

esClient.onEvent = { holdCoordinator.handle($0) }
esClient.onConnect = { esPusher.pushNow() }
daemon.server.onPolicyOrTrustChanged = { esPusher.pushNow() }

// Disks reported the moment they APPEAR (pre-mount), so the extension's
// BSD-name map is in place for the AUTH_MOUNT that follows insertion.
let diskWatcher = DiskAppearanceWatcher()
diskWatcher.onAppear = { bsdName, collectorKey in
    esPusher.diskAppeared(bsdName: bsdName, collectorDeviceKey: collectorKey)
}
diskWatcher.onGone = { bsdName in
    esPusher.diskGone(bsdName: bsdName)
    holdCoordinator.diskGone(bsdName: bsdName)
}

try daemon.start()
daemon.startEventFlow()

// Seeded boots attach no hardware sources and no ES link either: round-trip
// tests exercise the API surface, not the extension dial.
if !options.seeded {
    esClient.connect()
    esPusher.startHeartbeat()
    diskWatcher.start()
}

// No secrets in logs: the token itself never appears here — only its path.
print("plugsightd \(effectiveDaemonVersion) up — socket \(daemon.server.socketPath)")
print("plugsightd: database \(options.databasePath)\(options.seeded ? " (seeded)" : "")")
print("plugsightd: token file \(daemon.server.tokenPath)")

// MARK: - Clean shutdown on SIGINT/SIGTERM (daemon.stopped, L10)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let shutdown: () -> Void = {
    esPusher.stopHeartbeat()
    diskWatcher.stop()
    esClient.stop()
    daemon.stop()
    exit(0)
}
sigintSource.setEventHandler(handler: shutdown)
sigtermSource.setEventHandler(handler: shutdown)
sigintSource.resume()
sigtermSource.resume()

dispatchMain()
