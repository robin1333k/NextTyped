import AppKit
import SwiftUI

/// The sidebar material behind the Settings sidebar column: `NSVisualEffectView` with material
/// `.sidebar` and behind-window blending, the look of System Settings' sidebar in both appearances.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
