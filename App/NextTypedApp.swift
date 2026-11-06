import SwiftUI

/// Menu-bar agent entry point. `LSUIElement` (Info.plist) keeps it out of the Dock.
@main
struct NextTypedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @ObservedObject private var coordinator = AppCoordinator.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { coordinator.menuBarIconInserted },
            set: { coordinator.menuBarIconInsertionChanged(to: $0) })) {
            MenuBarContent()
                .environmentObject(coordinator)
        } label: {
            MenuBarIconLabel()
                .environmentObject(coordinator)
        }
        Settings {
            SettingsView()
                .environmentObject(coordinator)
        }
    }
}

/// Routes `nexttyped://settings` to whichever view currently owns `openSettings`. Two hosts
/// register: the menu-bar label (primary, exists only while the icon is inserted) and a hidden
/// window the delegate creates at launch (fallback, independent of the icon). A request
/// with no host yet (cold launch before the label subscribed) is queued and drained on register.
@MainActor
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()
    private var openers: [String: () -> Void] = [:]
    private var pending = false

    func register(_ id: String, _ open: @escaping () -> Void) {
        openers[id] = open
        if pending { pending = false; request() }
    }

    func unregister(_ id: String) { openers[id] = nil }

    func request() {
        guard let id = openers.keys.contains("label") ? "label" : openers.keys.sorted().first,
              let open = openers[id] else {
            pending = true
            #if DEBUG
            acLog("[deeplink]: queued reason=no-opener")
            #endif
            return
        }
        SettingsWindowConfigurator.Coordinator.openAndFront(open)
        #if DEBUG
        acLog("[deeplink]: opened via=%@ pane=%@", id, SettingsNavigation.shared.selection.rawValue)
        #endif
    }
}

/// Owns `openSettings` for deep links. Since macOS 14 the `showSettingsWindow:` selector no longer
/// opens a SwiftUI Settings scene, so the delegate cannot do it itself.
struct DeepLinkSettingsOpener: View {
    let id: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Label("NextTyped", systemImage: "text.cursor")
            .onAppear { DeepLinkRouter.shared.register(id) { openSettings() } }
            .onDisappear { DeepLinkRouter.shared.unregister(id) }
    }
}

/// The icon, plus the one route to Settings that exists while the menu is closed. `openSettings` is
/// only available inside a scene's views, and this label is the one view that lives as long as the icon.
/// A reopen of the running app sets `settingsRequestPending`; the label opens Settings through the same
/// path as the menu's button. No private selector is involved.
private struct MenuBarIconLabel: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The icon, plus today's accepted words when the switch is on. The words sit beside
        // the plain icon; nothing about the icon itself changes with a status.
        HStack(spacing: 4) {
            Image("MenuBarGlyph")   // template image from Assets.xcassets (scripts/make-icon.py)
            if let words = coordinator.menuBarWordsLabel { Text(words) }
        }
            .accessibilityLabel("NextTyped")
            .onAppear { DeepLinkRouter.shared.register("label") { openSettings() }; serveRequest() }
            .onDisappear { DeepLinkRouter.shared.unregister("label") }
            .onChange(of: coordinator.settingsRequestPending) { _, _ in serveRequest() }
    }

    private func serveRequest() {
        guard coordinator.settingsRequestPending else { return }
        SettingsWindowConfigurator.Coordinator.openAndFront { openSettings() }
        coordinator.settingsRequestServed()
    }
}
