import AppKit
import SwiftUI
import XCTest

@testable import WegaMacUpdater

final class WegaBrandArtworkTests: XCTestCase {
    @MainActor
    func testAppIconUsesApprovedArtwork() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let artwork = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent(
            "Sources/MacUpdater/Resources/WegaAppIcon.png"
        )))
        let expected = try pixels(Image(nsImage: artwork)
            .resizable().interpolation(.high).scaledToFit().frame(width: 128, height: 128))
        let actual = try pixels(WegaIcon(size: 128))

        XCTAssertEqual(actual.count, expected.count)
        let difference = zip(actual, expected).reduce(0.0) { total, pair in
            total + abs(Double(pair.0) - Double(pair.1)) / 255
        } / Double(expected.count)
        XCTAssertLessThan(difference, 0.015,
                          "WegaIcon must show the approved artwork, not the previous drawn app icon.")
    }

    @MainActor
    private func pixels<V: View>(_ view: V) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
