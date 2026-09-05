// ESExtensionBootstrap.swift
//
// The extension's whole runtime, assembled in one place: policy cache, the
// XPC listener the daemon dials, and the ES client whose AUTH_MOUNT handler
// is the enforcement point. The executable target (plugsight-esext) calls
// run() and nothing else, so EndpointSecurity stays imported by exactly this
// module.
//
// An Endpoint Security system extension is launched by sysextd as a plain
// process: create the ES client, park in dispatch_main(), and exit non-zero
// when the client cannot be created (no entitlement, not root, or ES denies
// it) — an extension without its ES client is not an extension, and exiting
// keeps status honest (no XPC service, no handshake, status.get stays
// inactive).

import EndpointSecurity
import Foundation
import os
import PlugsightESCore

public enum ESExtensionBootstrap {

    /// Assemble and run. Returns only by exiting the process.
    public static func run(
        teamID: String,
        bundleIDPrefix: String,
        daemonCodeSignIdentifier: String
    ) -> Never {
        let log = Logger(subsystem: "com.plugsight.esext", category: "main")

        let cacheBox = ESPolicyCacheBox()
        let listener = ESXPCListener(
            requirement: ESPeerRequirement(teamID: teamID, bundleIDPrefix: bundleIDPrefix),
            daemonBundleID: daemonCodeSignIdentifier,
            cacheBox: cacheBox
        )
        listener.resume()

        let client = PlugsightESClient(cacheBox: cacheBox, eventSink: { event in
            listener.forward(event)
        })
        let result = client.start()
        guard result == ES_NEW_CLIENT_RESULT_SUCCESS else {
            log.error("es_new_client failed (\(result.rawValue)) — exiting; mounts fail open by our absence")
            exit(EXIT_FAILURE)
        }
        log.log("plugsight ES extension up (mach service \(ESDefaults.machServiceName, privacy: .public))")

        // Park forever; the frame (and with it listener/client/cache) never
        // unwinds because dispatchMain never returns.
        dispatchMain()
    }
}
