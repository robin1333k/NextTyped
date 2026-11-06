import Testing
@testable import NextTypedCore

/// The Vision (normalised, bottom-left) → screen (points, top-left) transform.
/// The build spec calls this one out explicitly ("unit-test this transform") because a wrong flip
/// misattributes every block to the wrong window without ever crashing.
@Suite struct OCRGeometryTests {
    /// A 1440×900-point main display at the global origin.
    private let main = OCRRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func topLeftBoxStaysTopLeft() {
        // Vision: a box hugging the TOP-left of the image has a HIGH y (it is far from the bottom).
        let r = OCRGeometry.screenRect(
            normalizedX: 0, normalizedY: 0.9, normalizedWidth: 0.1, normalizedHeight: 0.1, in: main)
        #expect(r.minX == 0)
        #expect(abs(r.minY) < 0.001)  // flipped to the top of the screen (1 − 0.9 − 0.1 rounds off)
        #expect(r.width == 144)
        #expect(r.height == 90)
    }

    @Test func bottomLeftBoxLandsAtTheBottom() {
        let r = OCRGeometry.screenRect(
            normalizedX: 0, normalizedY: 0, normalizedWidth: 0.1, normalizedHeight: 0.1, in: main)
        #expect(r.minY == 810)        // 900 − 90
        #expect(r.maxY == 900)
    }

    @Test func centeredBoxStaysCentered() {
        let r = OCRGeometry.screenRect(
            normalizedX: 0.4, normalizedY: 0.4, normalizedWidth: 0.2, normalizedHeight: 0.2, in: main)
        let c = r.centroid
        #expect(abs(c.x - 720) < 0.001)
        #expect(abs(c.y - 450) < 0.001)
    }

    @Test func offsetsIntoASecondaryDisplaysGlobalFrame() {
        // A second display to the right of the main one: the block must land in ITS global band, not
        // at the global origin (this is what makes cross-monitor ambient context attributable).
        let secondary = OCRRect(x: 1440, y: 0, width: 1920, height: 1080)
        let r = OCRGeometry.screenRect(
            normalizedX: 0.5, normalizedY: 0.5, normalizedWidth: 0.1, normalizedHeight: 0.1, in: secondary)
        #expect(r.minX == 1440 + 960)
        #expect(r.minY == 1080 * 0.4)
    }

    @Test func fullFrameBoxCoversTheWholeDisplay() {
        let r = OCRGeometry.screenRect(
            normalizedX: 0, normalizedY: 0, normalizedWidth: 1, normalizedHeight: 1, in: main)
        #expect(r == main)
    }

    // MARK: pixel → points

    @Test func retinaPixelsHalveToPoints() {
        let size = OCRGeometry.pointSize(pixelWidth: 2880, pixelHeight: 1800, scale: 2)
        #expect(size.width == 1440)
        #expect(size.height == 900)
    }

    @Test func nonPositiveScaleDegradesToOneRatherThanNaN() {
        let size = OCRGeometry.pointSize(pixelWidth: 1440, pixelHeight: 900, scale: 0)
        #expect(size.width == 1440)
        #expect(size.height == 900)
    }

    // MARK: rect helpers used by attribution/ranking

    @Test func containsIsInclusiveAtMinAndExclusiveAtMax() {
        // Two abutting windows must never both claim a block sitting on their shared edge.
        let left = OCRRect(x: 0, y: 0, width: 100, height: 100)
        let right = OCRRect(x: 100, y: 0, width: 100, height: 100)
        #expect(left.contains(x: 0, y: 0) == true)
        #expect(left.contains(x: 100, y: 50) == false)
        #expect(right.contains(x: 100, y: 50) == true)
    }

    @Test func centroidDistanceIsEuclidean() {
        let a = OCRRect(x: 0, y: 0, width: 10, height: 10)      // centroid (5,5)
        let b = OCRRect(x: 30, y: 40, width: 10, height: 10)    // centroid (35,45)
        #expect(abs(a.centroidDistance(to: b) - 50) < 0.001)    // 30-40-50 triangle
    }
}
