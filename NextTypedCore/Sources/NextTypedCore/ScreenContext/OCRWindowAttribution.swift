import Foundation

/// **Window attribution + tiering**: turn a flat list of recognised text
/// blocks into "which window did this text come from, and what is that window to us?".
///
/// Attribution rule: a block belongs to the **first window in front-to-back z-order whose frame contains
/// the block's centroid**. Occluded windows therefore can't claim text drawn over them, which is what
/// makes "content one works with beats chrome" achievable geometrically rather than heuristically.
///
/// Known, deliberately-carried limit: a sidebar or toolbar drawn *inside* one
/// content window is **not** separable this way — the window list has no sub-window structure.
/// Mitigated only by ranking / confidence / head-caps; separating it needs an AX pass, which is exactly
/// what is unavailable on the AX-blind surfaces OCR exists to serve.
public enum OCRWindowAttribution {
    /// Bundle IDs of the system UI that *is* chrome no matter what layer it reports. The
    /// `windowLayer != 0` test catches most of it; this denylist is the backstop for the cases that
    /// draw at layer 0 (and documents intent).
    public static let systemChromeBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.mediaanalysisd",
        "com.apple.screencaptureui",
    ]

    /// One block, resolved to its window and prompt role.
    public struct AttributedBlock: Equatable, Sendable {
        public var block: OCRTextBlock
        /// `nil` when no window contained the block (desktop wallpaper, a transient overlay that
        /// vanished between the pixel capture and the window snapshot) — treated as chrome.
        public var window: ScreenWindow?
        public var tier: OCRTier

        public init(block: OCRTextBlock, window: ScreenWindow?, tier: OCRTier) {
            self.block = block
            self.window = window
            self.tier = tier
        }
    }

    /// Attribute every block and bucket it into a tier.
    ///
    /// - Parameters:
    ///   - blocks: recognised text, already in screen points (see `OCRGeometry`).
    ///   - windows: the `SCShareableContent` snapshot **in front-to-back z-order**.
    ///   - focusedWindowID: `CGWindowID` of the AX focused window, when known. Its blocks become
    ///     Tier 1 (the AX-blind fill candidate).
    ///   - screenBands: menu-bar / Dock bands per display — a geometric backstop for chrome that
    ///     reports layer 0 (see `isInChromeBand`).
    public static func attribute(
        blocks: [OCRTextBlock],
        windows: [ScreenWindow],
        focusedWindowID: UInt32?,
        screenBands: [OCRRect] = []
    ) -> [AttributedBlock] {
        blocks.map { block in
            let c = block.rect.centroid
            let window = windows.first { $0.rect.contains(x: c.x, y: c.y) }
            return AttributedBlock(
                block: block,
                window: window,
                tier: tier(for: window, focusedWindowID: focusedWindowID,
                           blockRect: block.rect, screenBands: screenBands))
        }
    }

    /// The tier of a block, given the window it was attributed to.
    static func tier(
        for window: ScreenWindow?,
        focusedWindowID: UInt32?,
        blockRect: OCRRect,
        screenBands: [OCRRect]
    ) -> OCRTier {
        // Unattributed text (desktop, a vanished overlay) is never injected.
        guard let window else { return .chrome }
        if isChrome(window) { return .chrome }
        // Geometric backstop: text sitting in a menu-bar / Dock band is chrome even if its window
        // claims layer 0.
        if isInChromeBand(blockRect, bands: screenBands) { return .chrome }
        if let focusedWindowID, window.windowID == focusedWindowID { return .focused }
        return .ambient
    }

    /// Whether a window is chrome by its own properties: a non-zero window layer (menu bar, Dock,
    /// pop-ups, floating panels) or a system-UI bundle.
    public static func isChrome(_ window: ScreenWindow) -> Bool {
        if window.layer != 0 { return true }
        if let bundleID = window.bundleID, systemChromeBundleIDs.contains(bundleID) { return true }
        return false
    }

    /// Whether a block's centroid falls in one of the menu-bar / Dock bands.
    static func isInChromeBand(_ rect: OCRRect, bands: [OCRRect]) -> Bool {
        let c = rect.centroid
        return bands.contains { $0.contains(x: c.x, y: c.y) }
    }
}
