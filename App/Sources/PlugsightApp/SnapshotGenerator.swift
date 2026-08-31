// SnapshotGenerator.swift
//
// The visual gate (07/04). Renders every surface state to PNG in BOTH light and
// dark, at normal and at-scale, using SwiftUI's ImageRenderer (macOS 13). Each
// picture is produced by driving the SAME view model the unit tests assert on
// against the SAME canned data, so the screenshots and the tests describe ONE
// fixture — an unviewed UI does not merge, and a lying picture cannot pass.
//
// Run: `PlugsightApp --snapshots <outputDir>`.

import AppKit
import SwiftUI
import PlugsightAppCore

@MainActor
enum SnapshotGenerator {

    struct Scene {
        let name: String        // <surface>-<variant>
        let atScale: Bool
        let size: CGSize
        let view: AnyView
    }

    struct ManifestEntry: Encodable {
        let surface: String
        let scheme: String
        let scale: String
        let file: String
    }

    static func run(outputDir: String) async -> Int {
        PSRender.snapshotMode = true  // flat columns so ImageRenderer captures lists
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let scenes = await buildScenes()
        var manifest: [ManifestEntry] = []

        for scene in scenes {
            for scheme in [ColorScheme.light, .dark] {
                let schemeName = scheme == .light ? "light" : "dark"
                let scaleName = scene.atScale ? "atscale" : "normal"
                let file = "\(scene.name)-\(schemeName)-\(scaleName).png"
                let bg = scheme == .dark ? Color(white: 0.12) : Color(white: 0.97)
                let wrapped = scene.view
                    .frame(width: scene.size.width, height: scene.size.height, alignment: .topLeading)
                    .background(bg)
                    .environment(\.colorScheme, scheme)

                let renderer = ImageRenderer(content: wrapped)
                renderer.scale = 2.0
                guard let nsImage = renderer.nsImage,
                      let tiff = nsImage.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write("failed to render \(file)\n".data(using: .utf8)!)
                    continue
                }
                do {
                    try png.write(to: dir.appendingPathComponent(file))
                    manifest.append(ManifestEntry(surface: scene.name, scheme: schemeName,
                                                  scale: scaleName, file: file))
                } catch {
                    FileHandle.standardError.write("write failed \(file): \(error)\n".data(using: .utf8)!)
                }
            }
        }

        // manifest.json lists every produced PNG for the reviewer/orchestrator.
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(manifest) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"))
        }
        print("Wrote \(manifest.count) PNGs + manifest.json to \(dir.path)")
        return manifest.count
    }

    // MARK: - Scene construction (drives the real view models)

    private static func buildScenes() async -> [Scene] {
        var scenes: [Scene] = []
        let popoverSize = CGSize(width: 340, height: 400)
        let windowSize = CGSize(width: 720, height: 520)
        let inspectorSize = CGSize(width: 380, height: 640)
        // Settings is a scrolling surface; the snapshot doesn't scroll, so the
        // scene is tall enough to show the whole page (incl. the extension row's
        // guided-step hint) without the fixed height compressing rows together.
        let settingsSize = CGSize(width: 720, height: 780)
        let onboardingSize = CGSize(width: 520, height: 470)

        // Glyph: all four forms in one gallery.
        scenes.append(Scene(name: "glyph", atScale: false,
                            size: CGSize(width: 380, height: 130),
                            view: AnyView(GlyphGalleryView())))

        // Popover states.
        for (variant, api) in [
            ("normal", FakeAPIClient()),
            ("empty", { let f = FakeAPIClient(alerts: .success(Canned.alertsEmpty));
                        f.timelineResult = .success(Canned.timelineEmpty); return f }()),
            ("degraded", FakeAPIClient(status: .success(Canned.statusDegraded))),
            ("stopped", FakeAPIClient(status: .success(Canned.statusStopped))),
            // At-scale: the popover's worst case — 3 alerts (capped) + 5 events +
            // a degraded footer. The canon says stress at 15-20 items; this is the
            // densest the popover ever renders, and the state the user actually hit.
            ("atscale", { let f = FakeAPIClient(status: .success(Canned.statusDegraded),
                                                timeline: .success(Canned.timelineAtScale),
                                                alerts: .success(Canned.alertsMany)); return f }()),
        ] {
            let vm = PopoverViewModel(api: api)
            await vm.load()
            scenes.append(Scene(name: "popover-\(variant)", atScale: false,
                                size: popoverSize, view: AnyView(PopoverView(state: vm.state))))
        }

        // Timeline states. The day-header humanizer is pinned to the canned
        // event day (Canned.timelineReferenceNow) so "Today"/"Yesterday" render
        // deterministically — a live clock would produce different PNG bytes on
        // every regeneration date.
        do {
            let refNow = Canned.timelineReferenceNow
            let normal = TimelineViewModel(api: FakeAPIClient()); await normal.load(now: refNow)
            scenes.append(Scene(name: "timeline-normal", atScale: false, size: windowSize,
                                view: AnyView(TimelineView(state: normal.state))))
            let emptyFake = FakeAPIClient(); emptyFake.timelineResult = .success(Canned.timelineEmpty)
            let empty = TimelineViewModel(api: emptyFake); await empty.load(now: refNow)
            scenes.append(Scene(name: "timeline-empty", atScale: false, size: windowSize,
                                view: AnyView(TimelineView(state: empty.state))))
            let scaleFake = FakeAPIClient(); scaleFake.timelineResult = .success(Canned.timelineAtScale)
            let scale = TimelineViewModel(api: scaleFake); await scale.load(now: refNow)
            scenes.append(Scene(name: "timeline-atscale", atScale: true, size: windowSize,
                                view: AnyView(TimelineView(state: scale.state))))
        }

        // Devices states.
        do {
            let normal = DevicesViewModel(api: FakeAPIClient()); await normal.load()
            scenes.append(Scene(name: "devices-normal", atScale: false, size: windowSize,
                                view: AnyView(DevicesView(state: normal.state))))
            let empty = DevicesViewModel(api: FakeAPIClient(devices: .success(Canned.devicesEmpty)))
            await empty.load()
            scenes.append(Scene(name: "devices-empty", atScale: false, size: windowSize,
                                view: AnyView(DevicesView(state: empty.state))))
            let scale = DevicesViewModel(api: FakeAPIClient(devices: .success(Canned.devicesAtScale)))
            await scale.load()
            scenes.append(Scene(name: "devices-atscale", atScale: true, size: windowSize,
                                view: AnyView(DevicesView(state: scale.state))))
        }

        // Inspector states.
        do {
            let normal = DeviceInspectorViewModel(api: FakeAPIClient(score: .success(Canned.scoreElevated)),
                                                  deviceId: "dev_charger")
            await normal.load()
            scenes.append(Scene(name: "inspector-normal", atScale: false, size: inspectorSize,
                                view: AnyView(DeviceInspectorView(state: normal.state))))
            let off = DeviceInspectorViewModel(api: FakeAPIClient(score: .success(Canned.scoreSensorOff)),
                                               deviceId: "dev_charger")
            await off.load()
            scenes.append(Scene(name: "inspector-sensoroff", atScale: false, size: inspectorSize,
                                view: AnyView(DeviceInspectorView(state: off.state))))
            let absentFake = FakeAPIClient(device: .success(Canned.deviceStorageAbsent),
                                           score: .success(Canned.scoreNoData))
            let absent = DeviceInspectorViewModel(api: absentFake, deviceId: "dev_webcam")
            await absent.load()
            scenes.append(Scene(name: "inspector-absent", atScale: false, size: inspectorSize,
                                view: AnyView(DeviceInspectorView(state: absent.state))))
        }

        // Settings states.
        do {
            let normal = SettingsViewModel(api: FakeAPIClient()); await normal.load()
            scenes.append(Scene(name: "settings-normal", atScale: false, size: settingsSize,
                                view: AnyView(SettingsView(state: normal.state))))
            let disabled = SettingsViewModel(api: FakeAPIClient(status: .success(Canned.statusScannerMissing)))
            await disabled.load()
            scenes.append(Scene(name: "settings-disabledprotection", atScale: false, size: settingsSize,
                                view: AnyView(SettingsView(state: disabled.state))))
        }

        // Onboarding states.
        do {
            let welcomeSteps = OnboardingViewModel.steps(from: Canned.statusDegraded)
            let welcome = OnboardingState(steps: welcomeSteps, currentIndex: 0, completionCopy: nil)
            scenes.append(Scene(name: "onboarding-welcome", atScale: false, size: onboardingSize,
                                view: AnyView(OnboardingView(state: welcome))))
            let permission = OnboardingState(steps: welcomeSteps, currentIndex: 1, completionCopy: nil)
            scenes.append(Scene(name: "onboarding-permission", atScale: false, size: onboardingSize,
                                view: AnyView(OnboardingView(state: permission))))
        }

        return scenes
    }
}
