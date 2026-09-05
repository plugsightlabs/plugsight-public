// plugsight-esext entry point: the executable inside
// com.plugsight.esext.systemextension (Contents/MacOS/plugsight-esext).
// DELIBERATELY four lines: everything lives in ESExtensionBootstrap
// (PlugsightESExtension), so this target never imports EndpointSecurity and
// the identity strings come from the one canonical source.
//
// CANNOT run unentitled: es_new_client requires root plus the restricted
// com.apple.developer.endpoint-security.client entitlement (docs/spec/07 L5).
// Compiling and bundling it is CI's job; running it is the entitled dev
// machine's (ESExtension/README.md).

import PlugsightCore
import PlugsightESExtension

ESExtensionBootstrap.run(
    teamID: PlugsightIdentifiers.teamID,
    bundleIDPrefix: PlugsightIdentifiers.bundleIDPrefix,
    daemonCodeSignIdentifier: PlugsightIdentifiers.daemonCodeSignIdentifier
)
