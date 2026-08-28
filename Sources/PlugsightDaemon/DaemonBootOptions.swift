// DaemonBootOptions.swift  (N8-G)
//
// Boot-time options for plugsightd: the production defaults, plus the
// `PLUGSIGHT_SEED_DB` dev flag and a chosen socket location so N9's
// `test:roundtrip` can drive all 19 tools against a seeded real daemon.
//
//   PLUGSIGHT_SEED_DB=<db path>   (or --seed <db path>)
//     Boot against an existing seeded database instead of the production one.
//     Seeded boots do not attach hardware sources.
//   PLUGSIGHT_STATE_DIR=<dir>     (or --socket <dir | path/to/plugsightd.sock>)
//     Where the socket + token live. Passing a *.sock path selects its parent
//     directory (the socket file name is fixed: plugsightd.sock).

import Foundation

public struct DaemonBootOptions: Equatable, Sendable {
    /// The SQLite database to open.
    public var databasePath: String
    /// Where plugsightd.sock and api-token live.
    public var stateDirectory: String
    /// True when booted against a seed DB (no hardware sources attached).
    public var seeded: Bool

    public init(databasePath: String, stateDirectory: String, seeded: Bool) {
        self.databasePath = databasePath
        self.stateDirectory = stateDirectory
        self.seeded = seeded
    }

    /// Parse CLI arguments + environment into boot options. CLI arguments take
    /// precedence over environment variables; both fall back to the production
    /// Application Support paths.
    public static func parse(
        arguments: [String],
        environment: [String: String],
        home: String = NSHomeDirectory()
    ) -> DaemonBootOptions {
        let productionDir = (home as NSString)
            .appendingPathComponent("Library/Application Support/Plugsight")

        var seedPath: String? = environment["PLUGSIGHT_SEED_DB"]
        var stateDir: String? = environment["PLUGSIGHT_STATE_DIR"]

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--seed":
                if index + 1 < arguments.count {
                    seedPath = arguments[index + 1]
                    index += 1
                }
            case "--socket":
                if index + 1 < arguments.count {
                    stateDir = arguments[index + 1]
                    index += 1
                }
            default:
                break
            }
            index += 1
        }

        // A *.sock path selects its parent directory (the socket file name is
        // fixed to plugsightd.sock by the server).
        if let dir = stateDir, dir.hasSuffix(".sock") {
            stateDir = (dir as NSString).deletingLastPathComponent
        }

        return DaemonBootOptions(
            databasePath: seedPath
                ?? (productionDir as NSString).appendingPathComponent("plugsight.db"),
            stateDirectory: stateDir ?? productionDir,
            seeded: seedPath != nil
        )
    }
}
