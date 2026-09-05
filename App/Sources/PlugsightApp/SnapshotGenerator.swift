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
        let windowSize = CGSize(width: 720, height: 520)
        let inspectorSize = CGSize(width: 380, height: 640)
        // Settings is a scrolling surface; the snapshot doesn't scroll, so the
        // scene is tall enough to show the whole page (incl. the extension row's
        // guided steps) without the fixed height compressing rows together.
        let settingsSize = CGSize(width: 720, height: 780)
        let onboardingSize = CGSize(width: 520, height: 470)

        // Glyph: all four forms in one gallery.
        scenes.append(Scene(name: "glyph", atScale: false,
                            size: CGSize(width: 380, height: 130),
                            view: AnyView(GlyphGalleryView())))

        // Popover states. The popover now sizes to content between 200 and 480;
        // each scene's height mirrors what the live popover would take, so the
        // gallery shows the REAL silhouette (short empty, tall at-scale).
        for (variant, height, api) in [
            ("normal", CGFloat(420), FakeAPIClient()),
            ("empty", 240, { let f = FakeAPIClient(alerts: .success(Canned.alertsEmpty));
                             f.timelineResult = .success(Canned.timelineEmpty); return f }()),
            ("degraded", 420, FakeAPIClient(status: .success(Canned.statusDegraded))),
            ("stopped", 240, FakeAPIClient(status: .success(Canned.statusStopped))),
            // At-scale: the popover's worst case — 3 alerts (capped) + 5 events +
            // a degraded footer. The canon says stress at 15-20 items; this is the
            // densest the popover ever renders, and the state the user actually hit.
            ("atscale", 480, { let f = FakeAPIClient(status: .success(Canned.statusDegraded),
                                                     timeline: .success(Canned.timelineAtScale),
                                                     alerts: .success(Canned.alertsMany)); return f }()),
        ] {
            let vm = PopoverViewModel(api: api)
            await vm.load()
            scenes.append(Scene(name: "popover-\(variant)", atScale: variant == "atscale",
                                size: CGSize(width: 340, height: height),
                                view: AnyView(PopoverView(state: vm.state))))
        }

        // Activity states (the event history behind the Devices-home link).
        // The day-header humanizer is pinned to the canned event day
        // (Canned.timelineReferenceNow) so "Today"/"Yesterday" render
        // deterministically — a live clock would produce different PNG bytes on
        // every regeneration date.
        do {
            let refNow = Canned.timelineReferenceNow
            let normal = TimelineViewModel(api: FakeAPIClient()); await normal.load(now: refNow)
            scenes.append(Scene(name: "activity-normal", atScale: false, size: windowSize,
                                view: AnyView(ActivityView(state: normal.state, onClose: {}))))
            let emptyFake = FakeAPIClient(); emptyFake.timelineResult = .success(Canned.timelineEmpty)
            let empty = TimelineViewModel(api: emptyFake); await empty.load(now: refNow)
            scenes.append(Scene(name: "activity-empty", atScale: false, size: windowSize,
                                view: AnyView(ActivityView(state: empty.state, onClose: {}))))
            let scaleFake = FakeAPIClient(); scaleFake.timelineResult = .success(Canned.timelineAtScale)
            let scale = TimelineViewModel(api: scaleFake); await scale.load(now: refNow)
            scenes.append(Scene(name: "activity-atscale", atScale: true, size: windowSize,
                                view: AnyView(ActivityView(state: scale.state, onClose: {}))))
            // Alerts only: the one real filter, showing the active alerts.
            let alertsVM = TimelineViewModel(api: FakeAPIClient(alerts: .success(Canned.alertsMany)))
            alertsVM.filters.activeAlertsOnly = true
            await alertsVM.load(now: refNow)
            scenes.append(Scene(name: "activity-alertsonly", atScale: false, size: windowSize,
                                view: AnyView(ActivityView(state: alertsVM.state, alertsOnly: true,
                                                           onClose: {}))))
        }

        // Devices home states (Direction C: verdict band + dense table). Times
        // are pinned to the canned event day so the cells render "Today …"
        // deterministically.
        do {
            let refNow = Canned.timelineReferenceNow
            let normal = DevicesViewModel(api: FakeAPIClient()); await normal.load(now: refNow)
            scenes.append(Scene(name: "devices-normal", atScale: false, size: windowSize,
                                view: AnyView(DevicesView(state: normal.state, onOpenActivity: {}))))
            let empty = DevicesViewModel(api: FakeAPIClient(devices: .success(Canned.devicesEmpty)))
            await empty.load(now: refNow)
            scenes.append(Scene(name: "devices-empty", atScale: false, size: windowSize,
                                view: AnyView(DevicesView(state: empty.state, onOpenActivity: {}))))
            let scale = DevicesViewModel(api: FakeAPIClient(devices: .success(Canned.devicesAtScale)))
            await scale.load(now: refNow)
            scenes.append(Scene(name: "devices-atscale", atScale: true, size: windowSize,
                                view: AnyView(DevicesView(state: scale.state, onOpenActivity: {}))))
        }

        // Inspector states: verdict-first (04). Normal = the yellow charger
        // with its reviewAlerts reason; unsafe = the infected drive with
        // quarantine + Restore; safe = a clean drive (DetailSafe artboard).
        do {
            let normal = DeviceInspectorViewModel(api: FakeAPIClient(score: .success(Canned.scoreElevated)),
                                                  deviceId: "dev_charger")
            await normal.load()
            scenes.append(Scene(name: "inspector-normal", atScale: false, size: inspectorSize,
                                view: AnyView(DeviceInspectorView(state: normal.state))))
            let unsafeFake = FakeAPIClient(device: .success(Canned.deviceStorageInfected),
                                           score: .success(Canned.scoreNoData),
                                           scans: .success(Canned.scansInfectedHistory))
            let unsafeVM = DeviceInspectorViewModel(api: unsafeFake, deviceId: "dev_sandisk")
            await unsafeVM.load()
            scenes.append(Scene(name: "inspector-unsafe", atScale: false, size: inspectorSize,
                                view: AnyView(DeviceInspectorView(state: unsafeVM.state))))
            let safeFake = FakeAPIClient(device: .success(Canned.deviceStorageClean),
                                         score: .success(Canned.scoreNoData),
                                         alerts: .success(Canned.alertsEmpty))
            let safeVM = DeviceInspectorViewModel(api: safeFake, deviceId: "dev_kingston")
            await safeVM.load()
            scenes.append(Scene(name: "inspector-safe", atScale: false, size: inspectorSize,
                                view: AnyView(DeviceInspectorView(state: safeVM.state))))
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

        // Settings states. extensionBundled is pinned per scene so the gallery
        // renders both honest extension rows deterministically (the default
        // provider would read the snapshot binary's own bundle).
        do {
            // Everything granted, scanner fresh, notifications default.
            let normal = SettingsViewModel(api: FakeAPIClient(),
                                           notificationAuthorization: { .authorized },
                                           extensionBundled: { false }, activationError: { nil })
            await normal.load()
            scenes.append(Scene(name: "settings-normal", atScale: false, size: settingsSize,
                                view: AnyView(SettingsView(state: normal.state))))
            // Input Monitoring granted, extension bundled-but-inactive with an
            // activation failure inline, scanner missing (guided install).
            let attention = SettingsViewModel(
                api: FakeAPIClient(status: .success(Canned.statusScannerMissing)),
                notificationAuthorization: { .authorized },
                extensionBundled: { true },
                activationError: { "Activation was not approved in System Settings." })
            await attention.load()
            scenes.append(Scene(name: "settings-scannermissing", atScale: false, size: settingsSize,
                                view: AnyView(SettingsView(state: attention.state))))
            // Stale definitions + denied notifications: the degraded promises.
            var staleStatus = Canned.statusActive
            staleStatus.scanner.definitionsAgeDays = 9
            let stale = SettingsViewModel(api: FakeAPIClient(status: .success(staleStatus)),
                                          notificationAuthorization: { .denied },
                                          extensionBundled: { false }, activationError: { nil })
            await stale.load()
            scenes.append(Scene(name: "settings-staledenied", atScale: false, size: settingsSize,
                                view: AnyView(SettingsView(state: stale.state))))
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
