// PeerValidator.swift
//
// XPC peer validation, modeled pure (02): both sides validate the peer's
// code-signing requirement — team ID plus bundle-id prefix — before
// exchanging anything. THIS CHECK FAILS CLOSED: missing, mismatched, or
// unverifiable identity rejects the connection. (Fail-open is mount policy
// only; handing policy or events to an unverified peer is never acceptable.)
//
// The plumbing enforces the same rule twice, deliberately:
//  1. NSXPCConnection.setCodeSigningRequirement(_:) with the string built
//     below — the OS-level gate.
//  2. This pure predicate over the audit-token-derived signing info — the
//     reviewed, testable restatement the checker reads against 02.

import Foundation

/// What we require of the peer: exact team, bundle id under our prefix.
public struct ESPeerRequirement: Equatable, Sendable {
    public let teamID: String
    public let bundleIDPrefix: String

    public init(teamID: String, bundleIDPrefix: String) {
        self.teamID = teamID
        self.bundleIDPrefix = bundleIDPrefix
    }

    /// The requirement string the plumbing installs on the NSXPCConnection.
    /// Exact identifier (the requirement language has no prefix glob for
    /// identifiers), Apple anchor, and the team in the leaf's subject.OU.
    public func codeSigningRequirementString(exactBundleID: String) -> String {
        "identifier \"\(exactBundleID)\" and anchor apple generic and "
            + "certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// What the peer actually presented, extracted by the plumbing from the
/// connection's code-signing info. Optionals model absence honestly.
public struct ESPresentedPeerInfo: Equatable, Sendable {
    public let teamID: String?
    public let bundleID: String?
    /// True only when the peer's signature statically validated.
    public let signingValid: Bool

    public init(teamID: String?, bundleID: String?, signingValid: Bool) {
        self.teamID = teamID
        self.bundleID = bundleID
        self.signingValid = signingValid
    }
}

public enum PeerValidator {
    /// Accept iff: signature valid, requirement non-degenerate, team an
    /// exact (case-sensitive) match, and bundle id anchored at our prefix.
    public static func validatePeer(
        requirement: ESPeerRequirement,
        presented: ESPresentedPeerInfo
    ) -> Bool {
        // A degenerate requirement must never become accept-all.
        guard !requirement.teamID.isEmpty, !requirement.bundleIDPrefix.isEmpty else {
            return false
        }
        guard presented.signingValid else { return false }
        guard let team = presented.teamID, team == requirement.teamID else {
            return false
        }
        guard let bundle = presented.bundleID,
              bundle.hasPrefix(requirement.bundleIDPrefix) else {
            return false
        }
        return true
    }
}
