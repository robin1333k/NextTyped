#if DEBUG
import AppKit
import NextTypedCore
import SwiftUI

/// Named states the renderer applies to the coordinator before it renders a pane. `live` is whatever the
/// current state is. Pane tickets of the `settings-design` spec add the fixtures they need here.
enum SettingsSnapshotFixture: String, CaseIterable {
    case live
    case modelFailed = "model-failed"
    case modelDownloading = "model-downloading"
    case modelReady = "model-ready"
    case accessibilityMissing = "accessibility-missing"
    case statisticsFilled = "statistics-filled"
    case statisticsManyApps = "statistics-many-apps"
    case ocrWaiting = "ocr-waiting"
    case ocrOn = "ocr-on"
    case profileUnreadable = "profile-unreadable"
    case personalizationOn = "personalization-on"
    case appsOnlySwitchedOn = "apps-only-switched-on"
    case paused
    case quiet

    /// The panes this fixture changes. `live` covers all of them; the others render only these.
    var panes: [SettingsSection] {
        switch self {
        case .live: SettingsSection.allCases
        case .modelFailed, .modelDownloading: [.setup, .general]
        case .modelReady: [.setup, .general]
        case .accessibilityMissing, .ocrOn: [.setup]
        case .statisticsFilled, .statisticsManyApps: [.statistics]
        case .ocrWaiting, .profileUnreadable: [.privacy]
        case .personalizationOn, .appsOnlySwitchedOn: [.apps]
        case .paused: [.general]
        case .quiet: [.apps]
        }
    }

    /// Sets the DEBUG state this fixture stands for.
    /// `baseline` is the model state from before the first fixture; every fixture starts from it, so none leaks into the next.
    @MainActor func apply(to coordinator: AppCoordinator, baseline: ModelLoadState) {
        coordinator.modelLoadState = baseline
        // The fake engine has no weights folder; only `model-ready` stands for a loaded model and names the local copy.
        coordinator.modelFolder = nil
        PermissionsModel.debugForceAccessibilityMissing = false
        coordinator.debugUsageStatistics = nil
        coordinator.debugScreenOCRNeedsPermission = nil
        coordinator.debugScreenOCRRequested = nil
        coordinator.debugSetLearnedProfileUnreadable(false)
        coordinator.debugPersonalizationEnabled = nil
        coordinator.debugAppDefaultMode = nil
        coordinator.debugSetStatus(paused: false, quietBundleID: nil)
        switch self {
        case .live: break
        case .modelReady:
            coordinator.modelLoadState = .ready
            coordinator.modelFolder = MLXPredictionEngine.localModelDirectory
        case .modelFailed: coordinator.modelLoadState = .failed
        case .modelDownloading: coordinator.modelLoadState = .downloading(0.42)
        case .accessibilityMissing: PermissionsModel.debugForceAccessibilityMissing = true
        case .statisticsFilled: coordinator.debugUsageStatistics = Self.filledStatistics
        case .statisticsManyApps: coordinator.debugUsageStatistics = Self.manyAppsStatistics
        // The switch stays off here on purpose: it reads `isScreenOCREnabled` (stored intent AND the OS grant),
        // and this state is "intent set, grant missing", so the real app also shows it off. The rule:
        // the switch shows the effective state, and the waiting notice beside it explains the missing grant.
        case .ocrWaiting: coordinator.debugScreenOCRNeedsPermission = true
        // OCR switched on, Screen Recording not granted: the Optional section with its attention row.
        case .ocrOn:
            coordinator.debugScreenOCRRequested = true
            coordinator.debugScreenOCRNeedsPermission = true
        case .profileUnreadable: coordinator.debugSetLearnedProfileUnreadable(true)
        case .personalizationOn: coordinator.debugPersonalizationEnabled = true
        case .appsOnlySwitchedOn: coordinator.debugAppDefaultMode = .onlySwitchedOn
        case .paused: coordinator.debugSetStatus(paused: true, quietBundleID: nil)
        // Calculator (first in the list) is listed through the added-app source; its quiet has 11 min 10 s left, shown as 12.
        case .quiet: coordinator.debugSetStatus(paused: false, quietBundleID: "com.apple.calculator")
        }
    }

    /// 14 days ending today, 5 apps. The numbers are fixed; only the chart's date labels follow the calendar.
    static let filledStatistics: UsageStatistics = {
        let apps = ["com.apple.TextEdit", "com.apple.Notes", "com.apple.Safari", "com.apple.mail",
                    "com.anthropic.claudefordesktop"]
        var statistics = UsageStatistics()
        let today = UsageDay.today()
        // Oldest first: `record` prunes relative to the day it is given.
        for offset in (0..<14).reversed() {
            let words = 12 + (offset * 7) % 23
            let app = apps[offset % apps.count]
            statistics.record(
                UsageBatch(acceptedWords: words, keystrokes: words * 9, activeSeconds: Double(words) * 6,
                           bundleID: app),
                on: today.advanced(by: -offset))
        }
        for (index, app) in apps.enumerated() {
            statistics.record(
                UsageBatch(acceptedWords: 5 + index, keystrokes: 40, activeSeconds: 30, bundleID: app),
                on: today)
        }
        return statistics
    }()
}

extension SettingsSnapshotFixture {
    /// 15 apps, one word-count each step apart: the By app list must show 12 rows and "and 3 more apps".
    static let manyAppsStatistics: UsageStatistics = {
        var statistics = UsageStatistics()
        let today = UsageDay.today()
        // Oldest first: `record` prunes relative to the day it is given.
        for index in (0..<15).reversed() {
            statistics.record(
                UsageBatch(acceptedWords: 40 - index * 2, keystrokes: 300, activeSeconds: 200,
                           bundleID: "com.example.app\(index)"),
                on: today.advanced(by: -max(0, index - 1)))
        }
        return statistics
    }()
}

/// Writes a PNG of every Settings pane, light and dark, at two sizes, from an offscreen window that is
/// never ordered on screen (`--render-settings <out-dir>`, `scripts/settings-snapshots.sh`).
///
/// Known limit: an offscreen window is not key, so AppKit-backed controls draw in the inactive state.
/// `.environment(\.controlActiveState,.key)` is applied to the root; where a control ignores it, the
/// inactive look is a renderer artefact, not a design bug.
@MainActor
struct SettingsSnapshotRenderer {
    let coordinator: AppCoordinator
    let outputDirectory: URL

    /// `(label, size)`: 560 is what the user sees first, `full` is the whole scroll content.
    static let sizes: [(label: String, size: NSSize)] = [
        ("560", NSSize(width: 780, height: 560)),
        ("full", NSSize(width: 780, height: 1400)),
    ]
    static let appearances: [(label: String, name: NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
    ]

    /// True when this process was launched with `--render-settings`.
    static var isRendering: Bool { outputDirectory(from: CommandLine.arguments) != nil }

    static func outputDirectory(from arguments: [String]) -> URL? {
        guard let flag = arguments.firstIndex(of: "--render-settings"),
              arguments.indices.contains(flag + 1) else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    func run() async {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("[render-settings]: cannot create \(outputDirectory.path): \(error)\n".utf8))
            return
        }
        let baseline = coordinator.modelLoadState
        for fixture in SettingsSnapshotFixture.allCases {
            fixture.apply(to: coordinator, baseline: baseline)
            for pane in fixture.panes {
                for appearance in Self.appearances {
                    for size in Self.sizes {
                        let name = "\(pane.rawValue)-\(fixture.rawValue)-\(appearance.label)-\(size.label).png"
                        await render(pane, appearance: appearance.name, size: size.size, to: outputDirectory.appendingPathComponent(name))
                    }
                }
            }
        }
        SettingsSnapshotFixture.live.apply(to: coordinator, baseline: baseline)
        // Extra page: the style kit gallery (`kit-gallery-<light|dark>-full.png`).
        for appearance in Self.appearances {
            // Taller than the pane pages: the gallery lists every component and must not cut off.
            let size = (label: "full", size: NSSize(width: 780, height: 2000))
            await render(SettingsKitGallery().background(Color(nsColor: .windowBackgroundColor)),
                         appearance: appearance.name, size: size.size,
                         to: outputDirectory.appendingPathComponent("kit-gallery-\(appearance.label)-\(size.label).png"))
        }
        // Extra page: the licences sheet (`about-licences-<light|dark>-full.png`), as the About pane opens it.
        for appearance in Self.appearances {
            await render(LicencesSheet(isPresented: .constant(true)).background(Color(nsColor: .windowBackgroundColor)),
                         appearance: appearance.name, size: NSSize(width: 560, height: 460),
                         to: outputDirectory.appendingPathComponent("about-licences-\(appearance.label)-full.png"))
        }
        // Extra pages: the bundled guides in their own window (`guide-<compatibility|uninstall>-<light|dark>-full.png`).
        for guide in [BundledGuide.compatibility, BundledGuide.uninstall] {
            guard let url = guide.bundledURL(), let markdown = try? String(contentsOf: url, encoding: .utf8) else {
                FileHandle.standardError.write(Data("[render-settings]: guide \(guide.rawValue) missing from bundle\n".utf8))
                continue
            }
            for appearance in Self.appearances {
                await render(GuideView(document: GuideDocument(markdown: markdown)),
                             appearance: appearance.name, size: NSSize(width: 640, height: 2000),
                             to: outputDirectory.appendingPathComponent("guide-\(guide.rawValue)-\(appearance.label)-full.png"))
            }
        }
    }

    private func render(_ pane: SettingsSection, appearance: NSAppearance.Name, size: NSSize, to url: URL) async {
        let root = SettingsView(initialSelection: pane)
            .environmentObject(coordinator)
            .background(Color(nsColor: .windowBackgroundColor))
        await render(root, appearance: appearance, size: size, to: url)
    }

    private func render<Content: View>(_ content: Content, appearance: NSAppearance.Name, size: NSSize, to url: URL) async {
        let root = content.environment(\.controlActiveState, .key)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Never ordered on screen. Let `.task` / `.onAppear` work finish on the main run loop.
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 500_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        window.contentView = nil
    }
}
#endif
