import Foundation

/// The pure-Core value types of the **screen-context OCR** pipeline (the pixel branch of
/// window context). The App layer owns the untestable machinery — ScreenCaptureKit capture, Vision
/// recognition, the `SCShareableContent` window snapshot — and hands the *results* across this seam as
/// plain values, so every decision worth testing (geometry transform, window attribution, tiering,
/// ranking, the OCR↔AX value-check, the pattern scrub, cadence) is unit-tested off the running app.
///
/// Pure Core: no CoreGraphics/AppKit/Vision/ScreenCaptureKit here — geometry crosses the seam as plain
/// `Double`s, mirroring the `CaretOverlap`/`FieldDescriptor` convention.

/// An axis-aligned rectangle in **screen points, top-left origin** (the coordinate space the App's
/// AX layer and `NSScreen` frames already speak). Kept deliberately separate from `CGRect` so Core
/// stays framework-free.
public struct OCRRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }
    public var centroid: (x: Double, y: Double) { (x + width / 2, y + height / 2) }

    /// Whether `point` lies inside (edges inclusive on the min side, exclusive on the max side — so
    /// two abutting windows never both claim a block on their shared edge).
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px < maxX && py >= minY && py < maxY
    }

    /// Distance between this rect's centroid and `other`'s — the raw input to the proximity term of
    /// the Tier-2 ranking.
    public func centroidDistance(to other: OCRRect) -> Double {
        let a = centroid, b = other.centroid
        return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

/// One recognised text block: what Vision read, where it sits on screen, and how sure it was.
public struct OCRTextBlock: Equatable, Sendable {
    public var text: String
    /// Screen-points rect, top-left origin (already through `OCRGeometry`).
    public var rect: OCRRect
    /// Vision's top-candidate confidence, 0…1. Low-confidence lines are dropped before injection.
    public var confidence: Double

    public init(text: String, rect: OCRRect, confidence: Double) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

/// A window as seen in the `SCShareableContent` snapshot taken with the pixels, reduced to the facts
/// the pure decisions need. The array order is **front-to-back z-order** (index 0 = frontmost), which
/// is what makes "first containing window wins" a correct attribution rule.
public struct ScreenWindow: Equatable, Sendable {
    /// `CGWindowID` — the stable identity used to key ranking/recency.
    public var windowID: UInt32
    public var bundleID: String?
    /// `SCWindow.windowLayer` — 0 is normal content; anything else is chrome (menu bar, Dock,
    /// pop-ups, floating panels).
    public var layer: Int
    /// Frame in screen points, top-left origin.
    public var rect: OCRRect
    /// Identifier of the display this window is on, so proximity can award a same-display bonus.
    public var displayID: UInt32

    public init(windowID: UInt32, bundleID: String?, layer: Int, rect: OCRRect, displayID: UInt32) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.layer = layer
        self.rect = rect
        self.displayID = displayID
    }
}

/// Which prompt role a block's window plays. Capture-scope ≠ injection-scope:
/// the capture is whole-screen, but only Tier 1 and Tier 2 can ever reach the prompt.
public enum OCRTier: Equatable, Sendable {
    /// Window chrome — menu bar, Dock, notifications, palettes. **Never injected.**
    case chrome
    /// The focused content window — the AX-blind *fallback* fill, and only when the OCR↔AX
    /// value-check finds net-new content (`OCRValueCheck`).
    case focused
    /// Another visible content window — *ambient* reference context, ranked and budgeted.
    case ambient
}
