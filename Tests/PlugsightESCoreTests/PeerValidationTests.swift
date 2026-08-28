// PeerValidationTests.swift
//
// N12 (02): both sides of the daemon<->extension XPC link validate the peer's
// code-signing requirement (team ID + bundle id prefix) before exchanging
// anything. The check is modeled pure — validatePeer(requirement, presented)
// -> Bool — and exercised with wrong-requirement fakes exactly as 07 asks:
// right team wrong bundle, wrong team, missing -> rejected; exact -> accepted.
// Unlike the mount path this check FAILS CLOSED: an unverified peer gets
// nothing, ever.

import XCTest
@testable import PlugsightESCore

final class PeerValidationTests: XCTestCase {

    let requirement = ESPeerRequirement(
        teamID: "PLUGSIGHTTEAM1",
        bundleIDPrefix: "com.plugsight."
    )

    func presented(
        team: String? = "PLUGSIGHTTEAM1",
        bundle: String? = "com.plugsight.daemon",
        valid: Bool = true
    ) -> ESPresentedPeerInfo {
        ESPresentedPeerInfo(teamID: team, bundleID: bundle, signingValid: valid)
    }

    // MARK: - Accept

    func testExactMatchAccepted() {
        XCTAssertTrue(PeerValidator.validatePeer(
            requirement: requirement, presented: presented()
        ))
    }

    func testAnyBundleUnderThePrefixAccepted() {
        XCTAssertTrue(PeerValidator.validatePeer(
            requirement: requirement,
            presented: presented(bundle: "com.plugsight.app")
        ))
    }

    // MARK: - Reject: the 07-mandated fakes

    func testRightTeamWrongBundleRejected() {
        XCTAssertFalse(PeerValidator.validatePeer(
            requirement: requirement,
            presented: presented(bundle: "com.evil.daemon")
        ))
    }

    func testWrongTeamRightBundleRejected() {
        XCTAssertFalse(PeerValidator.validatePeer(
            requirement: requirement,
            presented: presented(team: "EVILTEAM000001")
        ))
    }

    func testMissingTeamRejected() {
        XCTAssertFalse(PeerValidator.validatePeer(
            requirement: requirement, presented: presented(team: nil)
        ))
    }

    func testMissingBundleRejected() {
        XCTAssertFalse(PeerValidator.validatePeer(
            requirement: requirement, presented: presented(bundle: nil)
        ))
    }

    func testInvalidSignatureRejectedEvenWithMatchingIdentity() {
        XCTAssertFalse(PeerValidator.validatePeer(
            requirement: requirement, presented: presented(valid: false)
        ))
    }

    func testPrefixIsNotSubstringMatching() {
        // "com.plugsight." must anchor at the START of the bundle id.
        XCTAssertFalse(PeerValidator.validatePeer(
            requirement: requirement,
            presented: presented(bundle: "com.evil.com.plugsight.daemon")
        ))
    }

    func testEmptyRequirementNeverValidates() {
        // A misconfigured empty requirement must reject everything rather
        // than become an accept-all. Fail closed on the config, too.
        let empty = ESPeerRequirement(teamID: "", bundleIDPrefix: "")
        XCTAssertFalse(PeerValidator.validatePeer(
            requirement: empty, presented: presented()
        ))
    }

    func testCaseSensitiveTeamID() {
        XCTAssertFalse(PeerValidator.validatePeer(
            requirement: requirement,
            presented: presented(team: "plugsightteam1")
        ))
    }

    // MARK: - The requirement string the plumbing installs on the connection

    func testCodeSigningRequirementStringShape() {
        let str = requirement.codeSigningRequirementString(
            exactBundleID: "com.plugsight.daemon"
        )
        XCTAssertEqual(
            str,
            "identifier \"com.plugsight.daemon\" and anchor apple generic and "
                + "certificate leaf[subject.OU] = \"PLUGSIGHTTEAM1\""
        )
    }
}
