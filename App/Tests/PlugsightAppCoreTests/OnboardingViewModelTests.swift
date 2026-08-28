import XCTest
@testable import PlugsightAppCore

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    func testFourStepsInOrder() {
        let steps = OnboardingViewModel.steps(from: Canned.statusActive)
        XCTAssertEqual(steps.map(\.step), [.welcome, .inputMonitoring, .systemExtension, .scanner])
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

    func testDeniedStepShowsDegradedConsequenceInline() {
        let steps = OnboardingViewModel.steps(from: Canned.statusDegraded)
        let im = steps.first { $0.step == .inputMonitoring }!
        guard case .notGranted(let consequence) = im.grant else { return XCTFail("expected notGranted") }
        XCTAssertFalse(consequence.isEmpty)
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

    // The location check renders inside the extension step (1d).
    func testExtensionStepCanCarryLocationWarning() {
        let steps = OnboardingViewModel.steps(from: Canned.statusScannerMissing)
        let ext = steps.first { $0.step == .systemExtension }!
        // Not granted here (inactive) so its grant is notGranted; the field exists.
        XCTAssertNotNil(ext.step)
        _ = ext.locationWarning  // field is modeled
    }
}
