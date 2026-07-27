import SwiftUI
import XCTest

@testable import WegaMacUpdater

/// ARCH-08d — the 9-lane binary stream must measure each lane's glyph text once,
/// statically, instead of re-measuring on every 30 fps animation frame.
final class BinaryStreamStaticMeasurementTests: XCTestCase {
    func testGlyphTextIsMeasuredOncePerLaneAndNotOnEveryFrame() {
        let lanes = BinaryStreamLaneFactory.make(lanes: 9, baseSpeed: 38)
        var measurements = 0
        let renderer = BinaryStreamFrameRenderer(lanes: lanes) { _ in
            measurements += 1
            return CGSize(width: 120, height: 12)
        }

        XCTAssertEqual(
            measurements,
            lanes.count,
            "each lane's glyph text must be measured exactly once, at construction"
        )

        let canvas = CGSize(width: 400, height: 200)
        for frame in 0..<30 {
            _ = renderer.placements(at: TimeInterval(frame) / 30.0, canvasSize: canvas)
        }

        XCTAssertEqual(
            measurements,
            lanes.count,
            "rendering successive 30 fps frames must not re-measure glyph text"
        )
    }

    func testFrameGeometryStillAdvancesBetweenFrames() {
        let lanes = BinaryStreamLaneFactory.make(lanes: 9, baseSpeed: 38)
        let renderer = BinaryStreamFrameRenderer(lanes: lanes) { _ in
            CGSize(width: 120, height: 12)
        }
        let canvas = CGSize(width: 400, height: 200)

        XCTAssertNotEqual(
            renderer.placements(at: 0, canvasSize: canvas),
            renderer.placements(at: 1, canvasSize: canvas),
            "the stream must still drift across frames after measurement is hoisted out"
        )
    }

    func testZeroWidthLanesContributeNoPlacements() {
        let lanes = BinaryStreamLaneFactory.make(lanes: 3, baseSpeed: 38)
        let renderer = BinaryStreamFrameRenderer(lanes: lanes) { _ in
            CGSize(width: 0, height: 12)
        }

        XCTAssertTrue(
            renderer.placements(at: 0, canvasSize: CGSize(width: 400, height: 200)).isEmpty,
            "lanes that measure to zero width must be skipped, as before"
        )
    }
}
