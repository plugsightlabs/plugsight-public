// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Plugsight",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PlugsightCore", targets: ["PlugsightCore"]),
        .library(name: "PlugsightDaemon", targets: ["PlugsightDaemon"]),
        .executable(name: "plugsightd", targets: ["plugsightd"]),
        .library(name: "PlugsightESCore", targets: ["PlugsightESCore"]),
        .library(name: "PlugsightESExtension", targets: ["PlugsightESExtension"]),
        // N10: the menu-bar app. AppCore holds the API client + view models +
        // SwiftUI views (CI-testable, no live socket needed). PlugsightApp is the
        // @main executable that wires NSStatusItem/popover/window on top.
        .library(name: "PlugsightAppCore", targets: ["PlugsightAppCore"]),
        .executable(name: "PlugsightApp", targets: ["PlugsightApp"]),
    ],
    dependencies: [
        // GRDB links system SQLite (not IOKit/CoreGraphics/EndpointSecurity), so
        // PlugsightCore stays platform-neutral and the seam gate still passes.
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        // Platform-neutral core. MUST NOT import IOKit/CoreGraphics/EndpointSecurity.
        // The seam is enforced by ops/check-seam.sh.
        .target(
            name: "PlugsightCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                // The legit-composite allowlist ships as data (05), loaded
                // via Bundle.module in Allowlist.loadShipped().
                .process("Detection/allowlist.json"),
            ]
        ),
        // Daemon library: will later hold Collector/Scorer/Scanning/API and the
        // platform-specific DeviceEventSource implementations (N8+).
        .target(
            name: "PlugsightDaemon",
            dependencies: ["PlugsightCore"]
        ),
        // Minimal executable that compiles today; real wiring is N8.
        .executableTarget(
            name: "plugsightd",
            dependencies: ["PlugsightDaemon"]
        ),
        // Shared test support: FakeDeviceEventSource and fixtures. Importable from
        // test targets and the backbone of all later detection tests.
        .target(
            name: "PlugsightTestKit",
            dependencies: ["PlugsightCore"]
        ),
        .testTarget(
            name: "PlugsightCoreTests",
            dependencies: [
                "PlugsightCore",
                "PlugsightTestKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "PlugsightDaemonTests",
            dependencies: ["PlugsightDaemon", "PlugsightTestKit"]
        ),
        // N12: the PURE Endpoint Security decision layer (07). Deadline budget,
        // mount-hold decision, XPC peer-requirement validation, policy cache
        // freshness. MUST NOT import EndpointSecurity — that is the point: this
        // layer is CI-testable without the ES framework, root, or the L5
        // entitlement. Depends on PlugsightCore only for shared vocabulary
        // (TrustTier). Purity is guarded by a test in PlugsightESCoreTests.
        .target(
            name: "PlugsightESCore",
            dependencies: ["PlugsightCore"]
        ),
        // N12: the RUTHLESSLY THIN ES/XPC plumbing. The only target in the
        // package allowed to import EndpointSecurity. It compiles in CI but
        // cannot run there (needs root + the ES entitlement, 07); every
        // decision it makes is a call into PlugsightESCore.
        .target(
            name: "PlugsightESExtension",
            dependencies: ["PlugsightESCore"],
            linkerSettings: [
                .linkedFramework("EndpointSecurity"),
            ]
        ),
        .testTarget(
            name: "PlugsightESCoreTests",
            dependencies: ["PlugsightESCore"]
        ),
        // N10 (07): the menu-bar app, structured as SPM so the view models are
        // CI-testable. AppCore may import SwiftUI/AppKit; it depends on
        // PlugsightCore only for shared vocabulary (TrustTier, DetectionSeverity).
        // The seam gate only guards PlugsightCore, so this is fine.
        .target(
            name: "PlugsightAppCore",
            dependencies: ["PlugsightCore"],
            path: "App/Sources/PlugsightAppCore"
        ),
        .executableTarget(
            name: "PlugsightApp",
            dependencies: ["PlugsightAppCore"],
            path: "App/Sources/PlugsightApp"
        ),
        .testTarget(
            name: "PlugsightAppCoreTests",
            dependencies: ["PlugsightAppCore", "PlugsightCore"],
            path: "App/Tests/PlugsightAppCoreTests"
        ),
        // N-API-PARITY: the PERMANENT cross-decode parity gate. It depends on BOTH
        // the daemon (which produces the wire shapes) and the app core (which
        // consumes them), encodes each method's real daemon result exactly as the
        // wire does, and DECODES it with the corresponding UI DTO. It fails the
        // moment daemon output and UI DTO drift apart again.
        .testTarget(
            name: "ContractParityTests",
            dependencies: ["PlugsightDaemon", "PlugsightAppCore", "PlugsightCore"],
            path: "Tests/ContractParityTests"
        ),
    ]
)
