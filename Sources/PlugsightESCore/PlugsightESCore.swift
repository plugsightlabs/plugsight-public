// PlugsightESCore
//
// N12's PURE decision layer for the Endpoint Security system extension (02, 07).
// Everything the AUTH_MOUNT handler and the XPC listener must DECIDE lives here
// as pure, unit-tested functions; the ES/XPC plumbing in PlugsightESExtension is
// ruthlessly thin and only calls in.
//
// HARD RULE: this target must never `import EndpointSecurity`. The purity guard
// test in PlugsightESCoreTests greps these sources and fails the suite if the
// import appears.

/// Marker for the target; real types live in the sibling files.
public enum PlugsightESCoreInfo {
    /// Build-graph node that owns this target (docs/spec/07).
    public static let nodeID = "N12"
}
