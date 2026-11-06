import AppKit
import NextTypedCore
import SwiftUI

/// A guide from `docs/`, bundled as a resource and shown in our own window. The repository is
/// private, so a GitHub URL would give every DMG recipient a 404.
enum BundledGuide: String, Hashable {
    /// `docs/uninstall.md`
    case uninstall
    /// `docs/compatibility.md`
    case compatibility

    /// The alert text when the resource is missing from the bundle.
    private var title: String {
        switch self {
        case .uninstall: return "The uninstall guide"
        case .compatibility: return "The compatibility list"
        }
    }

    /// The bundled copy, or nil when the resource is missing from the bundle.
    func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: rawValue, withExtension: "md")
    }

    /// The window title.
    private var windowTitle: String {
        switch self {
        case .uninstall: return "Uninstall NextTyped"
        case .compatibility: return "Compatibility"
        }
    }

    /// Open guide windows, one per guide. A second click brings the open one to the front.
    @MainActor private static var windows: [BundledGuide: NSWindow] = [:]

    /// Shows the guide in our own window, rendered from the bundled Markdown (`GuideDocument`). Returns
    /// false and logs `[settings]` when the resource is missing or unreadable.
    @MainActor @discardableResult
    func open(in bundle: Bundle = .main) -> Bool {
        if let window = Self.windows[self] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        guard let source = bundledURL(in: bundle) else {
            acLog("[settings]: guide missing from bundle name=%@", rawValue)
            return false
        }
        guard let markdown = try? String(contentsOf: source, encoding: .utf8) else {
            acLog("[settings]: guide missing from bundle name=%@", rawValue)
            return false
        }
        let window = Self.makeWindow(title: windowTitle, markdown: markdown)
        Self.windows[self] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { Self.windows[self] = nil }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @MainActor
    private static func makeWindow(title: String, markdown: String) -> NSWindow {
        let hosting = NSHostingController(rootView: GuideView(document: GuideDocument(markdown: markdown)))
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 600))
        window.contentMinSize = NSSize(width: 460, height: 360)
        window.center()
        return window
    }

    /// Opens the guide, or tells the user it could not be opened.
    @MainActor
    func openOrAlert() {
        guard !open() else { return }
        let alert = NSAlert()
        alert.messageText = "\(title) could not be opened"
        alert.informativeText = "The file is missing from this copy of NextTyped. Reinstall the app, or read docs/\(rawValue).md in the GitHub repository."
        alert.runModal()
    }
}
