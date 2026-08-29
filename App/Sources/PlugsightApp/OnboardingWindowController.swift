// OnboardingWindowController.swift — the first-run onboarding window host.
//
// Mounts the live onboarding walk (OnboardingFlowView over the N11 machine with
// the REAL macOS drivers) in an NSWindow. This is where the shipped app registers
// plugsightd as a login item: the Welcome step's "Get started" drives
// SMAppService.agent("com.plugsight.daemon.plist"), whose plist the release build
// bundles at Contents/Library/LaunchAgents. Shown once: completing the walk OR
// closing the window records first-run-seen, so onboarding never nags (canon:
// Skip is never punished). Permissions stay reachable later via System Settings
// deep links in the app's Settings surface.

import AppKit
import SwiftUI
import PlugsightAppCore

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// First-run marker. Set on completion or close, never checked again after.
    static let seenDefaultsKey = "onboarding.seen"

    static var shouldPresent: Bool {
        !UserDefaults.standard.bool(forKey: seenDefaultsKey)
    }

    private var window: NSWindow?

    func present() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let machine = OnboardingStateMachine(
            probe: MacPermissionProbing(),
            activator: MacExtensionActivating(extensionIdentifier: "com.plugsight.esextension"),
            loginItem: MacLoginItemRegistering(plistName: "com.plugsight.daemon.plist"),
            location: MacAppLocationChecking())
        let controller = OnboardingFlowController(machine: machine) {
            UserDefaults.standard.set(true, forKey: Self.seenDefaultsKey)
        }
        let hosting = NSHostingController(rootView: OnboardingFlowView(controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Plugsight"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing mid-walk counts as seen: the walk is offered once, and every
        // permission stays reachable later (Skip is never punished).
        UserDefaults.standard.set(true, forKey: Self.seenDefaultsKey)
        window = nil
    }
}
