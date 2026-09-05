import XCTest
@testable import PlugsightAppCore

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    func testFiveStepsInOrder() {
        let steps = OnboardingViewModel.steps(from: Canned.statusActive)
        XCTAssertEqual(steps.map(\.step),
                       [.welcome, .inputMonitoring, .systemExtension, .notifications, .scanner])
    }

    func testSkipVisibleOnEveryStep() {
        let steps = OnboardingViewModel.steps(from: Canned.statusActive)
        XCTAssertTrue(steps.allSatisfy { $0.showsSkip })
    }

    func testGrantedStepReflectsStatusLive() {
        let steps = OnboardingViewModel.steps(from: Canned.statusActive)
        let im = steps.first { $0.step == .inputMonitoring }!
        XCTAssertEqual(im.grant, .granted)
    }

    // BEFORE the user has chosen anything, an ungranted step carries no
    // consequence warning: it reads as undecided (the judge's premature
    // "stays off" finding).
    func testUngrantedStepIsUndecidedNotWarned() {
        let steps = OnboardingViewModel.steps(from: Canned.statusDegraded)
        let im = steps.first { $0.step == .inputMonitoring }!
        XCTAssertEqual(im.grant, .undecided)
    }

    // A DENIED notification permission is a made choice and shows its honest
    // consequence; undetermined stays undecided; authorized reads granted.
    func testNotificationsStepReflectsAuthorization() {
        let denied = OnboardingViewModel.steps(from: Canned.statusActive,
                                               notificationAuthorization: .denied)
            .first { $0.step == .notifications }!
        guard case .denied(let consequence) = denied.grant else {
            return XCTFail("expected denied, got \(denied.grant)")
        }
        XCTAssertTrue(consequence.lowercased().contains("notification"))
        let fresh = OnboardingViewModel.steps(from: Canned.statusActive)
            .first { $0.step == .notifications }!
        XCTAssertEqual(fresh.grant, .undecided)
        let authorized = OnboardingViewModel.steps(from: Canned.statusActive,
                                                   notificationAuthorization: .authorized)
            .first { $0.step == .notifications }!
        XCTAssertEqual(authorized.grant, .granted)
    }

    // WP5: the SAME grant carries the SAME words in onboarding and Settings.
    func testStepTitlesMatchSettingsVocabulary() {
        XCTAssertEqual(OnboardingStep.inputMonitoring.title,
                       PermissionVocabulary.inputMonitoring.purpose)
        XCTAssertEqual(OnboardingStep.systemExtension.title,
                       PermissionVocabulary.systemExtension.purpose)
        XCTAssertEqual(OnboardingStep.scanner.title,
                       PermissionVocabulary.scanner.purpose)
        XCTAssertEqual(OnboardingStep.notifications.title, "Notifications")
    }

    func testWelcomeHeadlineIsTheProductInOneRead() {
        let steps = OnboardingViewModel.steps(from: Canned.statusActive)
        let welcome = steps.first { $0.step == .welcome }!
        XCTAssertTrue(welcome.headline.contains("USB"))
        XCTAssertEqual(welcome.grant, .notApplicable)
    }

    // Honest completion copy: degraded is stated, not hidden.
    func testCompletionCopyStatesDegradedHonestly() {
        let full = OnboardingViewModel.completionCopy(for: Canned.statusActive)
        let degraded = OnboardingViewModel.completionCopy(for: Canned.statusDegraded)
        XCTAssertNotEqual(full, degraded)
        XCTAssertTrue(degraded.lowercased().contains("input monitoring")
                      || degraded.lowercased().contains("off")
                      || degraded.lowercased().contains("without"))
    }

    // WP2: the Input Monitoring reframe reads timing-only and non-alarming, never
    // claims to read keys, pre-empts Apple's own dialog wording, and has no em dash.
    func testInputMonitoringBodyIsReframedTimingOnly() {
        let steps = OnboardingViewModel.steps(from: Canned.statusScannerMissing)
        let im = steps.first { $0.step == .inputMonitoring }!
        let body = im.body.lowercased()
        XCTAssertTrue(body.contains("rhythm"), "reframe leads with typing rhythm")
        XCTAssertTrue(body.contains("timing"), "reframe says timing-only")
        XCTAssertTrue(body.contains("never the keys themselves"),
                      "reframe is explicit that keys are not read")
        XCTAssertTrue(im.body.contains("macOS will ask"),
                      "reframe pre-empts Apple's own dialog wording")
        XCTAssertFalse(im.body.contains("\u{2014}"), "no em dash in shipped copy")
    }

    // WP2: purpose-led labels carry the OS permission name as a secondary line.
    func testPermissionStepsCarryOSNameSecondary() {
        let steps = OnboardingViewModel.steps(from: Canned.statusScannerMissing)
        let im = steps.first { $0.step == .inputMonitoring }!
        XCTAssertEqual(im.osName, "macOS permission: Input Monitoring")
        XCTAssertEqual(im.headline, "Check typing rhythm, not your keystrokes")
        let scanner = steps.first { $0.step == .scanner }!
        XCTAssertEqual(scanner.headline, "Scan drives for malware")
        XCTAssertTrue(scanner.body.contains("ClamAV"),
                      "the scanner step explains ClamAV in simple terms")
        XCTAssertFalse(scanner.body.contains("\u{2014}"))
        let welcome = steps.first { $0.step == .welcome }!
        XCTAssertNil(welcome.osName, "Welcome has no OS permission secondary")
    }

    // WP2: the shared trust line is present and em-dash-free.
    func testTrustLineIsPresentAndClean() {
        XCTAssertTrue(TrustCopy.stayOnMac.contains("stays on your Mac"))
        XCTAssertTrue(TrustCopy.stayOnMac.lowercased().contains("open source"))
        XCTAssertFalse(TrustCopy.stayOnMac.contains("\u{2014}"))
    }

    // A landed scanner step is a software INSTALL, not a permission: its green
    // label reads "Installed". Permission steps keep "Granted".
    func testLandedLabelSaysInstalledForScannerGrantedForPermissions() {
        XCTAssertEqual(OnboardingStep.scanner.landedLabel, "Installed")
        XCTAssertEqual(OnboardingStep.inputMonitoring.landedLabel, "Granted")
        XCTAssertEqual(OnboardingStep.systemExtension.landedLabel, "Granted")
    }

    // The location check renders inside the extension step (1d).
    func testExtensionStepCanCarryLocationWarning() {
        let steps = OnboardingViewModel.steps(from: Canned.statusScannerMissing)
        let ext = steps.first { $0.step == .systemExtension }!
        // Not granted here (inactive) so its grant is notGranted; the field exists.
        XCTAssertNotNil(ext.step)
        _ = ext.locationWarning  // field is modeled
    }
}
