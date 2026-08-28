// ScanAlertCopy.swift
//
// The user-facing alert sentence for a scan finding (docs/spec/05). It names the
// file, the signature, and the COMPLETED action. The report-only wording is
// load-bearing: when containment failed (read-only volume), the alert says so
// exactly instead of claiming the file was quarantined.

import Foundation

public enum ScanAlertCopy {

    /// Alert summary for one infected file. `file` is shown by its last path
    /// component to keep the sentence readable while remaining unambiguous. When
    /// the action is report-only, `reason` selects the honest explanation.
    public static func infected(
        file: String,
        signature: String,
        action: FindingAction,
        reason: ContainmentFailure = .readOnlyVolume
    ) -> String {
        let name = (file as NSString).lastPathComponent
        switch action {
        case .quarantined:
            return "Infected file “\(name)” (\(signature)) was moved to quarantine."
        case .reportedOnly:
            let cause: String
            switch reason {
            case .readOnlyVolume: cause = "the volume is read-only"
            case .unsafeSymlink:  cause = "it was a symlink and was not followed for safety"
            case .policyDisabled: cause = "quarantine is disabled in your settings"
            }
            return "Infected file “\(name)” (\(signature)) was found but could not be "
                + "contained because \(cause). Reported only, left in place, NOT quarantined."
        }
    }
}
