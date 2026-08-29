// AppDelegate.swift — the AppKit shell.
//
// Owns the NSStatusItem glyph, the popover, and the main window. Every surface it
// mounts is a SwiftUI view from PlugsightAppCore driven by a tested view model.
// The delegate itself holds no product logic: it polls status, feeds the glyph
// view model (which applies the stopped>alert>degraded>idle precedence), reloads
// the popover, and hosts the SwiftUI content. Startup shows stopped-hollow until
// the first heartbeat, so the glyph never claims monitoring that isn't running.

import AppKit
import Darwin
import SwiftUI
import PlugsightAppCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    // PLUGSIGHT_STATE_DIR must reach the app AND the daemon identically, or the
    // app talks to a socket the daemon never opened (ops/dev-run.sh sets it for
    // both). nil falls back to ~/Library/Application Support/Plugsight.
    private let api: APIClient = LiveAPIClient(
        stateDirectory: ProcessInfo.processInfo.environment["PLUGSIGHT_STATE_DIR"])
    private var pollTimer: Timer?
    private var startingUp = true
    private var instanceLockFD: Int32 = -1
    // Created in applicationDidFinishLaunching: the window controller is
    // MainActor-isolated, and a stored-property default would run off it.
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleInstance() else {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyGlyph(.stopped)  // stopped-hollow until first heartbeat (canon)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 400)
        setPopover(.loading)

        // Poll status on a heartbeat; the glyph and popover follow it.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()

        // First run: offer the onboarding walk (register the daemon login item,
        // then the permission steps). Shown once; Skip/close is never punished.
        if OnboardingWindowController.shouldPresent {
            let onboarding = OnboardingWindowController()
            self.onboarding = onboarding
            onboarding.present()
        }
    }

    /// Only one Plugsight may own the menu-bar shield. Bundled builds are
    /// deduplicated by bundle id via NSRunningApplication; a `swift run` build
    /// has no bundle id, so it takes a non-blocking exclusive flock on a lock
    /// file in the state dir instead (released by the kernel on process exit).
    private func claimSingleInstance() -> Bool {
        if let bundleID = Bundle.main.bundleIdentifier {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != myPID }
            if let other = others.first {
                other.activate(options: [])
                return false
            }
            return true
        }
        let stateDir = ProcessInfo.processInfo.environment["PLUGSIGHT_STATE_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Plugsight")
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let lockPath = (stateDir as NSString).appendingPathComponent("app.lock")
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }  // cannot create the lock: never refuse to launch
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        instanceLockFD = fd  // held for the process lifetime
        return true
    }

    private func refresh() {
        Task { @MainActor in
            let status = try? await api.getStatus()
            startingUp = false
            let glyph = GlyphViewModel.state(status: status, startingUp: status == nil && startingUp)
            applyGlyph(glyph)
            let popoverVM = PopoverViewModel(api: api)
            await popoverVM.load()
            setPopover(popoverVM.state)
        }
    }

    private func setPopover(_ state: PopoverState) {
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state))
    }

    /// Render the glyph FORM (not only tint) for a state.
    private func applyGlyph(_ state: GlyphState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch state {
        case .idle: symbol = "shield.fill"
        case .degraded: symbol = "shield.lefthalf.filled"
        case .alert: symbol = "exclamationmark.shield.fill"
        case .stopped: symbol = "shield"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Plugsight: \(state.accessibilityPhrase)")
        button.image?.isTemplate = state != .alert  // alert uses the semantic palette
        button.contentTintColor = state == .alert ? .systemOrange : nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Open the main window (sidebar Timeline/Devices/Settings + inspector pane).
    @objc func openMainWindow() {
        if let w = mainWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingController(rootView: MainWindowView(api: api))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Plugsight"
        window.setContentSize(NSSize(width: 820, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
