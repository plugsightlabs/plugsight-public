// main.swift — Plugsight menu-bar app entry point.
//
// The @main executable wires the AppKit shell (NSStatusItem glyph, popover, main
// window) onto the tested view models in PlugsightAppCore. It is a thin host: all
// state logic lives in AppCore so it is CI-testable without a live daemon.
//
// This file stays deliberately small; the surfaces are built in AppCore/Views and
// mounted by AppShell.

import AppKit
import PlugsightAppCore

// Snapshot mode: render every surface to PNG (the visual gate) and exit, without
// starting the menu-bar app. `PlugsightApp --snapshots <dir>`.
if let idx = CommandLine.arguments.firstIndex(of: "--snapshots") {
    let out = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : "App/Snapshots"
    // ImageRenderer needs the AppKit run loop live, so start the app and drive the
    // render from a main-actor task, then terminate. Blocking the main thread with
    // a semaphore would deadlock the main-actor task.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        _ = await SnapshotGenerator.run(outputDir: out)
        NSApp.terminate(nil)
    }
    app.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu-bar-only, no Dock icon
app.run()
