#if DEBUG
import AppKit
import NextTypedCore
import SwiftUI

/// `--render-onboarding <out-dir>` (DEBUG): a PNG of every onboarding page, light and dark, drawn in an
/// offscreen window, then quit. No event tap, no model load, no window on screen. Files are
/// `onboarding-<fixture>-<light|dark>.png`; `scripts/settings-snapshots.sh` runs it after the Settings
/// panes. The Model fixtures set the load state by hand, so no download runs.
@MainActor
struct OnboardingSnapshotRenderer {
    enum Fixture: String, CaseIterable {
        case tryTab = "try-tab"
        case permissionMissing = "permission-missing"
        case modelDownloading = "model-downloading"
        case modelDiskTooSmall = "model-disk-too-small"
        case modelReady = "model-ready"
        case practice

        var page: OnboardingPage {
            switch self {
            case .tryTab: .tryTab
            case .permissionMissing: .permission
            case .modelDownloading, .modelDiskTooSmall, .modelReady: .model
            case .practice: .practice
            }
        }
    }

    let coordinator: AppCoordinator
    let outputDirectory: URL

    static func outputDirectory(from arguments: [String]) -> URL? {
        guard let flag = arguments.firstIndex(of: "--render-onboarding"),
              arguments.indices.contains(flag + 1) else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    func run() async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        ModelPage.debugForceHubSource = true
        for fixture in Fixture.allCases {
            apply(fixture)
            for appearance in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
                let url = outputDirectory.appendingPathComponent("onboarding-\(fixture.rawValue)-\(appearance.1).png")
                await render(OnboardingView(coordinator: coordinator, startPage: fixture.page)
                                .background(Color(nsColor: .windowBackgroundColor)),
                             appearance: appearance.0, to: url)
            }
        }
    }

    private func apply(_ fixture: Fixture) {
        PermissionsModel.debugForceAccessibilityMissing = fixture == .permissionMissing
        coordinator.modelDiskShortfall = nil
        switch fixture {
        case .modelDownloading:
            coordinator.modelLoadState = .downloading(0.25)
        case .modelDiskTooSmall:
            coordinator.modelLoadState = .failed
            coordinator.modelDiskShortfall = .tooSmall(neededBytes: 4_512_276_480, freeBytes: 2_254_857_830)
        case .tryTab, .permissionMissing, .modelReady, .practice:
            coordinator.modelLoadState = .ready
        }
    }

    private func render<Content: View>(_ content: Content, appearance: NSAppearance.Name, to url: URL) async {
        let hosting = NSHostingView(rootView: content.environment(\.controlActiveState, .key))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 480, height: 440))
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
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
