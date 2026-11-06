import Foundation

/// The **Vision → screen** coordinate transform, lifted into Core because it is
/// the one piece of the OCR pipeline that is both easy to get silently wrong and trivially testable.
///
/// Vision reports each observation's `boundingBox` **normalised (0…1) with a BOTTOM-LEFT origin**,
/// relative to the image it recognised. Every consumer downstream — window attribution, the menu-bar /
/// Dock band backstop, proximity ranking — works in **screen points with a TOP-LEFT origin** (the space
/// AX rects and the App's flipped `NSScreen` frames already use). Getting the flip wrong doesn't crash;
/// it silently attributes every block to the wrong window, which is exactly the class of bug a unit test
/// should catch rather than a runtime session.
///
/// **Scale drops out.** The capture is taken at native pixel resolution (`points × scaleFactor`) of one
/// display, so a normalised box maps directly onto that display's *points* rect — the `/scale` the raw
/// pixel route needs is already folded into `displayRect`. `pointSize(pixelWidth:…)` is the helper the
/// App uses to derive that rect's size from the capture configuration.
public enum OCRGeometry {
    /// Map a Vision `boundingBox` (normalised, bottom-left origin) to a screen-points rect with a
    /// top-left origin, given the points rect of the display the image was captured from.
    ///
    /// - Parameters:
    ///   - normalizedX/Y/Width/Height: the observation's `boundingBox` components, where `y` is the
    ///     distance from the **bottom** of the image to the box's bottom edge.
    ///   - displayRect: the capturing display's frame in global screen points, **top-left origin**.
    public static func screenRect(
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        in displayRect: OCRRect
    ) -> OCRRect {
        let width = normalizedWidth * displayRect.width
        let height = normalizedHeight * displayRect.height
        let x = displayRect.minX + normalizedX * displayRect.width
        // Flip: Vision's `y` measures up from the bottom edge to the box's BOTTOM, so the box's top
        // in a top-left space sits `1 - (y + height)` of the way down.
        let y = displayRect.minY + (1.0 - normalizedY - normalizedHeight) * displayRect.height
        return OCRRect(x: x, y: y, width: width, height: height)
    }

    /// Points size of a capture taken at native pixel resolution — the inverse of the
    /// `config.width = points × scaleFactor` the App sets on `SCStreamConfiguration`. A non-positive
    /// scale degrades to 1 rather than producing an infinite/NaN rect.
    public static func pointSize(pixelWidth: Double, pixelHeight: Double, scale: Double)
        -> (width: Double, height: Double)
    {
        let s = scale > 0 ? scale : 1
        return (pixelWidth / s, pixelHeight / s)
    }
}
