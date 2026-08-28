// PlugsightESExtension
//
// N12's RUTHLESSLY THIN Endpoint Security / XPC plumbing (02, 07). This is the
// ONLY target in the package allowed to import EndpointSecurity. It compiles in
// CI but cannot run there (root + the com.apple.developer.endpoint-security.client
// entitlement are required, 07); the recorded gate for the live path is the
// manual SIP-relaxed dev-machine session. Every decision is delegated to
// PlugsightESCore.

import EndpointSecurity
import PlugsightESCore
