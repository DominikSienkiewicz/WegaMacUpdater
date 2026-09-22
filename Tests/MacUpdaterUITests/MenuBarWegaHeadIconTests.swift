import AppKit
import Testing

@testable import WegaMacUpdater

// The menu-bar item used to be `shippingbox` — a parcel, for an app whose whole face is a dog.
//
// A glyph this small cannot be graded by looking at it, and this machine cannot take a
// screenshot of the menu bar, so these tests read the rendered alpha instead: how many separate
// shapes a given row crosses, and how many holes are enclosed by the silhouette. That is enough
// to say "two ears above one head, with two eyes and a nose punched through it" without
// asserting a single coordinate — the geometry can be nudged, the face has to stay a face.

@Suite("The menu-bar item is Wega, not a shipping box")
struct MenuBarWegaHeadIconTests {

    /// Raster size for the shape tests. Far above the 18 points the menu bar asks for, so the
    /// eye holes are several pixels across and an alpha threshold reads geometry rather than
    /// antialiasing.
    private static let side = 128

    @Test @MainActor
    func theImageIsATemplateSizedForTheMenuBar() {
        let image = WegaHeadGlyph.menuBarImage

        #expect(image.isTemplate,
                """
                A status-item image must be a template: AppKit paints it from the alpha channel \
                to match the bar, which is what makes it legible in light and dark and inverted \
                while the menu is open.
                """)
        #expect(image.size == WegaHeadGlyph.menuBarSize)
        #expect(WegaHeadGlyph.menuBarSize.height <= 18,
                "18 points is the tallest a status item's image may be before AppKit scales it")
    }

    /// Red before the glyph existed: `shippingbox` is one closed outline, so every row across it
    /// is a single run — there were no two ears to find.
    @Test @MainActor
    func twoEarsStandAboveOneHead() throws {
        let mask = try Self.renderedMask()
        let box = try #require(mask.paintedRows, "the glyph must paint something")

        let earRow = mask.runs(inRow: box.minY + Int(0.2 * Double(box.height)))
        #expect(earRow.count == 2,
                """
                A fifth of the way down the glyph is ear height: two separate triangles with the \
                sky between them. Found \(earRow.count) shape(s) — the ears have merged into a \
                blob, or lost their gap.
                """)

        let chinRow = mask.runs(inRow: box.minY + Int(0.9 * Double(box.height)))
        #expect(chinRow.count == 1,
                "Near the bottom the glyph is one solid chin, below the nose. Found \(chinRow.count).")
    }

    /// The face, stated as the only thing that survives at 18 points: three holes in a silhouette.
    /// Fills would not do — a template image keeps no colour, so a dark nose drawn onto a filled
    /// head is a dark nose on a dark head.
    @Test @MainActor
    func theSilhouetteHasTwoEyesAndANosePunchedThroughIt() throws {
        let mask = try Self.renderedMask()

        #expect(mask.enclosedHoleCount == 3,
                """
                Expected three holes enclosed by the head — two eyes and a nose — and found \
                \(mask.enclosedHoleCount). Zero means the features were painted as fills, which \
                vanish in a template image.
                """)
    }

    @Test @MainActor
    func theGlyphKeepsItsMarginsClear() throws {
        let mask = try Self.renderedMask()
        let last = Self.side - 1

        for (x, y) in [(0, 0), (last, 0), (0, last), (last, last)] {
            #expect(!mask[x, y], "the glyph must not run into the corners of the menu-bar item")
        }

        let box = try #require(mask.paintedRows)
        #expect(box.height >= Int(0.8 * Double(Self.side)),
                "and it must still fill the item — a head shrunk to a dot reads as nothing at all")
    }

    /// The guard that stops the parcel coming back. The ten other `shippingbox` icons in the app
    /// are genuinely boxes; this file is the one place the symbol stood in for the dog.
    ///
    /// It matches the opening quote, not the bare name, so the file may still say in prose what
    /// it used to draw — the regression is naming that symbol, not remembering it.
    @Test
    func theMenuBarLabelNoLongerDrawsAShippingBox() throws {
        let source = try Self.read("Sources/MacUpdater/MenuBarScene.swift")

        #expect(!source.contains("\"shippingbox"),
                "the menu-bar item is Wega's head — a parcel icon here is the regression")
        #expect(source.contains("WegaHeadGlyph"),
                "…and it draws it through the glyph, so the shape stays in one place")
    }

    // MARK: - Reading the rendered glyph

    @MainActor private static func renderedMask() throws -> AlphaMask {
        try AlphaMask(rendering: WegaHeadGlyph.menuBarImage, side: side)
    }

    private static func read(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// A square of "is this pixel painted", read from the image's alpha channel.
private struct AlphaMask {
    enum Failure: Error { case couldNotRasterize }

    let side: Int
    private let opaque: [Bool]

    subscript(x: Int, y: Int) -> Bool { opaque[y * side + x] }

    init(rendering image: NSImage, side: Int) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw Failure.couldNotRasterize }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.current?.flushGraphics()

        guard let pixels = rep.bitmapData else { throw Failure.couldNotRasterize }
        let rowBytes = rep.bytesPerRow
        let stride = rep.samplesPerPixel

        var painted = [Bool](repeating: false, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                painted[y * side + x] = pixels[y * rowBytes + x * stride + 3] > 127
            }
        }

        self.side = side
        self.opaque = painted
    }

    /// The rows carrying any paint: where the glyph starts and how tall it stands.
    var paintedRows: (minY: Int, height: Int)? {
        let rows = (0..<side).filter { y in (0..<side).contains { self[$0, y] } }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        return (top, bottom - top + 1)
    }

    /// The uninterrupted painted stretches across one row — two of them at ear height, one at
    /// the chin, three where the eyes cut the face into cheeks and a bridge.
    func runs(inRow y: Int) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var start: Int?
        for x in 0..<side {
            switch (self[x, y], start) {
            case (true, nil):            start = x
            case (false, let begin?):    found.append(begin..<x); start = nil
            default:                     break
            }
        }
        if let begin = start { found.append(begin..<side) }
        return found
    }

    /// Unpainted regions the silhouette closes around. Everything reachable from the border is
    /// the background; whatever transparency is left is a hole, and each connected group counts
    /// once.
    var enclosedHoleCount: Int {
        var outside = [Bool](repeating: false, count: side * side)
        var queue: [(Int, Int)] = []

        for i in 0..<side {
            for (x, y) in [(i, 0), (i, side - 1), (0, i), (side - 1, i)] where !self[x, y] {
                if !outside[y * side + x] {
                    outside[y * side + x] = true
                    queue.append((x, y))
                }
            }
        }
        flood(from: &queue, into: &outside)

        var counted = [Bool](repeating: false, count: side * side)
        var holes = 0
        for y in 0..<side {
            for x in 0..<side
            where !self[x, y] && !outside[y * side + x] && !counted[y * side + x] {
                counted[y * side + x] = true
                var group: [(Int, Int)] = [(x, y)]
                flood(from: &group, into: &counted)
                holes += 1
            }
        }
        return holes
    }

    /// Breadth-first spread across unpainted neighbours, marking each one visited.
    private func flood(from queue: inout [(Int, Int)], into visited: inout [Bool]) {
        while let (x, y) = queue.popLast() {
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < side && ny < side {
                guard !self[nx, ny], !visited[ny * side + nx] else { continue }
                visited[ny * side + nx] = true
                queue.append((nx, ny))
            }
        }
    }
}
