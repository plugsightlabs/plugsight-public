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
        // Left-click toggles the popover; right-click (or control-click) opens a
        // small menu so the main window and Quit are always reachable even when
        // the popover is empty (GAP-1: the window had no opener before).
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

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
            let onboarding = OnboardingWindowController(api: api)
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
        // Wire the popover's recovery buttons back into the shell: Open Plugsight
        // and the degraded "Grant" open the main window (on Settings for Grant);
        // "Start monitoring" registers the daemon login item and re-polls (GAP-2/5).
        let actions = PopoverActions(
            openPlugsight: { [weak self] in self?.openMainWindow() },
            startMonitoring: { [weak self] in self?.startMonitoring() },
            grant: { [weak self] in self?.openMainWindow(section: .settings) })
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(state: state, actions: actions))
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

    /// Left-click toggles the popover; right-click / control-click opens the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isMenuClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isMenuClick { showStatusMenu() } else { togglePopover() }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// A minimal right-click menu so the window and Quit are always reachable.
    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Plugsight", action: #selector(openMainWindow as () -> Void), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Plugsight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Start monitoring from the daemon-down popover: register the packaged agent
    /// as a login item (which launches plugsightd), then re-poll so the glyph and
    /// popover reflect the new state (GAP-5: the button did nothing before).
    @objc private func startMonitoring() {
        if #available(macOS 13.0, *) {
            try? MacLoginItemRegistering(plistName: "com.plugsight.daemon.plist").register()
        }
        refresh()
    }

    /// Open the main window (sidebar Timeline/Devices/Settings + inspector pane).
    @objc func openMainWindow() { openMainWindow(section: .timeline) }

    /// Open (or front) the main window, landing on a specific section. An existing
    /// window is only fronted; the initial section applies when it is first built.
    func openMainWindow(section: MainSection) {
        if let w = mainWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingController(rootView: MainWindowView(api: api, initialSection: section))
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
