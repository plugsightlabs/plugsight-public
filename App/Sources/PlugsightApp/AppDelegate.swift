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
import PlugsightCore
import PlugsightAppCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    // The popover is built ONCE: one view model, one hosting controller. The 5 s
    // poll only reloads the view model; SwiftUI updates in place and the hosting
    // controller's sizingOptions feed the fitting size to the popover, so the
    // surface never flickers from a contentViewController rebuild and never
    // centre-clips (height follows content between the view's 200...480 bounds).
    private var popoverVM: PopoverViewModel?
    // Whether this build ships the .systemextension (the same guard onboarding
    // uses). Feeds the glyph + popover honesty gate: an uninstallable extension
    // must never cause a permanent degraded state.
    private var extensionBundled = true
    // PLUGSIGHT_STATE_DIR must reach the app AND the daemon identically, or the
    // app talks to a socket the daemon never opened (ops/dev-run.sh sets it for
    // both). nil falls back to ~/Library/Application Support/Plugsight.
    private let api: APIClient = LiveAPIClient(
        stateDirectory: ProcessInfo.processInfo.environment["PLUGSIGHT_STATE_DIR"])
    private var pollTimer: Timer?
    private var startingUp = true
    // The upgrade-hazard watchdog (pure logic, unit-tested in PlugsightAppCore):
    // after a start attempt with a registered service and no reachable daemon,
    // it asks for one registration recycle, then the honest stopped advisory.
    private var startSupervisor = DaemonStartSupervisor()
    private var instanceLockFD: Int32 = -1
    // Created in applicationDidFinishLaunching: the window controller is
    // MainActor-isolated, and a stored-property default would run off it.
    private var onboarding: OnboardingWindowController?
    // Wave 2 live-update spine: one long-lived tail subscription feeds the
    // notification engine and the debounced refresh signal the main window
    // observes. The popover keeps its own 5 s status poll.
    private var notifications: NotificationManager?
    private var refreshSignal: RefreshCoordinator?
    private var eventStream: EventStreamService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleInstance() else {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyGlyph(.stopped)  // stopped-hollow until first heartbeat (canon)
        registerScriptingHooks()
        // Left-click toggles the popover; right-click (or control-click) opens a
        // small menu so the main window and Quit are always reachable even when
        // the popover is empty (GAP-1: the window had no opener before).
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        extensionBundled = MacExtensionActivating(
            extensionIdentifier: PlugsightIdentifiers.esExtensionBundleID).bundledExtensionPresent()

        popover = NSPopover()
        popover.behavior = .transient
        buildPopoverOnce()

        // Poll status on a heartbeat; the glyph and popover follow it.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()

        // Notifications + live updates (Wave 2). The system center needs a real
        // app bundle; a bare `swift run` build falls back to the no-op center so
        // dev runs never crash. Authorization is asked once, explicitly
        // (.alert + .sound), only while the user has never answered.
        let apiRef = api
        let center: NotificationCenterClient
        if let system = SystemNotificationCenterClient() {
            center = system
        } else {
            center = NoopNotificationCenterClient()
        }
        let manager = NotificationManager(
            center: center,
            policy: { try? await apiRef.getPolicy() },
            deviceName: { id in (try? await apiRef.getDevice(id: id))?.name })
        notifications = manager
        // First run, the onboarding walk owns the notification ask (its own
        // step, with context); asking here too would fire the OS dialog over
        // the Welcome card. Later launches keep the ask-once-at-start.
        if !OnboardingWindowController.shouldPresent {
            Task { await manager.requestAuthorizationIfNeeded() }
        }

        let signal = RefreshCoordinator()
        refreshSignal = signal
        let stream = EventStreamService(api: apiRef, notifications: manager, refresh: signal)
        eventStream = stream
        Task { await stream.start() }

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
            let glyph = GlyphViewModel.state(status: status,
                                             startingUp: status == nil && startingUp,
                                             extensionBundled: extensionBundled)
            applyGlyph(glyph)
            superviseStart(daemonReachable: status != nil)
            await popoverVM?.load()
        }
    }

    /// Feed the heartbeat into the start supervisor and run what it asks for:
    /// one automatic unregister+register after a start attempt that left a
    /// registered service unreachable (the post-update launch-constraint kill),
    /// then the honest advisory in the popover stopped state.
    private func superviseStart(daemonReachable: Bool) {
        if daemonReachable { popoverVM?.startAdvisory = nil }
        guard #available(macOS 13.0, *) else { return }
        let registering = MacLoginItemRegistering(plistName: "com.plugsight.daemon.plist")
        switch startSupervisor.notePoll(daemonReachable: daemonReachable,
                                        serviceRegistered: registering.isRegistered()) {
        case .none:
            break
        case .recycleRegistration:
            registering.recycle()
        case .advise(let advisory):
            popoverVM?.startAdvisory = advisory
        }
    }

    /// Build the popover's view model + hosting controller exactly once. The
    /// root view observes the model, so every later refresh is a state update on
    /// the SAME controller — never a contentViewController swap. sizingOptions
    /// publishes the SwiftUI fitting size as preferredContentSize, which the
    /// popover tracks, so height follows content (short when empty, capped at
    /// the view's max, top-aligned, never centre-clipped).
    private func buildPopoverOnce() {
        // Wire the popover's recovery buttons back into the shell: Open Plugsight
        // and the degraded "Grant" open the main window (on Settings for Grant);
        // "Start monitoring" registers the daemon login item and re-polls
        // (GAP-2/5); Details routes to the alert's device; Reopen re-runs the load.
        let actions = PopoverActions(
            openPlugsight: { [weak self] in self?.openFromPopover { $0.openMainWindow() } },
            startMonitoring: { [weak self] in self?.startMonitoring() },
            grant: { [weak self] in self?.openFromPopover { $0.openMainWindow(section: .settings) } },
            openDevice: { [weak self] deviceId in
                self?.openFromPopover { $0.openDevice(deviceId: deviceId) }
            },
            reload: { [weak self] in self?.refresh() })
        let vm = PopoverViewModel(api: api, extensionBundled: extensionBundled)
        popoverVM = vm
        let hosting = NSHostingController(rootView: PopoverRootView(model: vm, actions: actions))
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.preferredContentSize]
        }
        popover.contentViewController = hosting
    }

    /// Close the popover, then run a shell route (opening a window from a
    /// transient popover should dismiss the popover first).
    private func openFromPopover(_ route: (AppDelegate) -> Void) {
        popover.performClose(nil)
        route(self)
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
        startSupervisor.noteStartAttempt()
        refresh()
    }

    /// Finder/Dock reopen (LSUIElement app): open the main window instead of
    /// doing nothing (live-walk defect 9).
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    /// Open the main window (sidebar Timeline/Devices/Settings + inspector pane).
    @objc func openMainWindow() { openMainWindow(section: .devices) }

    // Darwin-notify scripting hooks so audits and support can drive the shell
    // without accessibility scripting: `notifyutil -p com.plugsight.hook.window`
    // opens the main window, `...hook.popover` toggles the popover. Local-only
    // (Darwin notifications never leave the machine) and side-effect-free
    // beyond showing UI that the menu bar already offers.
    private func registerScriptingHooks() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.openMainWindow() }
        }, "com.plugsight.hook.window" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePopover() }
        }, "com.plugsight.hook.popover" as CFString, nil, .deliverImmediately)
    }

    /// The pane-minimum geometry the window must never shrink below. Computed
    /// from MainWindowView's declared minimums (sidebar + devices pane +
    /// divider + inspector) so the split view can always lay the three panes
    /// side by side; a window smaller than this made SwiftUI float the sidebar
    /// ON TOP of the devices pane (live-walk defect 1).
    private static let mainWindowMinContent = NSSize(
        width: MainWindowView.minContentSize.width,
        height: MainWindowView.minContentSize.height)
    private static let mainWindowFrameName = "plugsight.mainWindow"

    /// Open (or front) the main window, landing on a specific section. An existing
    /// window is only fronted; the initial section applies when it is first built.
    func openMainWindow(section: MainSection) {
        if let w = mainWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        var authProvider: (@Sendable () async -> NotificationAuthorization)?
        if let manager = notifications {
            authProvider = { @Sendable in await manager.authorization() }
        }
        let hosting = NSHostingController(rootView: MainWindowView(
            api: api, initialSection: section,
            refresh: refreshSignal, notificationAuthorization: authProvider))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Plugsight"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Geometry: never below the pane minimums, open at (or above) them, and
        // keep the user's size/position across launches. The window object also
        // survives close (isReleasedWhenClosed = false) so reopening is a front,
        // never a use-after-release.
        window.contentMinSize = Self.mainWindowMinContent
        window.setContentSize(NSSize(width: Self.mainWindowMinContent.width + 40, height: 620))
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.mainWindowFrameName) {
            window.center()
        }
        // A frame saved by an older build can be narrower than the new pane
        // minimums; restoring it would re-create the sidebar-overlay bug, so
        // clamp the restored content size up to the minimum.
        var content = window.contentRect(forFrameRect: window.frame).size
        if content.width < Self.mainWindowMinContent.width
            || content.height < Self.mainWindowMinContent.height {
            content.width = max(content.width, Self.mainWindowMinContent.width)
            content.height = max(content.height, Self.mainWindowMinContent.height)
            window.setContentSize(content)
        }
        window.setFrameAutosaveName(Self.mainWindowFrameName)
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Route to one device: front the main window on Devices, then tell the
    /// window which device to select. The notification is posted on the next
    /// runloop turn so a freshly built MainWindowView has attached its listener.
    func openDevice(deviceId: String) {
        openMainWindow(section: .devices)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("plugsight.openDevice"),
                object: nil,
                userInfo: ["deviceId": deviceId])
        }
    }
}

/// The popover's stable root: observes the ONE view model the shell keeps, so
/// state updates re-render in place inside the ONE hosting controller.
private struct PopoverRootView: View {
    @ObservedObject var model: PopoverViewModel
    let actions: PopoverActions
    var body: some View {
        PopoverView(state: model.state, actions: actions)
    }
}
