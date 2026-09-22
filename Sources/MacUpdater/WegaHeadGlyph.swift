import AppKit
import CoreGraphics

/// Wega's head as a single template shape, for the menu-bar item.
///
/// The coordinates are the app icon's — the same 100×100 viewBox `WegaIcon` draws and
/// `scripts/make-icon.swift` renders into `AppIcon.icns` — so the item in the menu bar is
/// recognisably the same dog as the icon in the Dock. This is deliberately a third copy of those
/// numbers: folding the three into one source is a refactor of `WegaIcon` and the icon script,
/// which this glyph does not need and should not drag along.
///
/// Eyes and nose are holes, not dark fills. A template image carries no colour — AppKit reads
/// its alpha and paints the result to match the bar — so features drawn *onto* a filled head
/// would disappear into it. The silhouette is therefore assembled as ears ∪ head, minus the
/// features, and the result is one path with three holes in it.
enum WegaHeadGlyph {

    /// The menu-bar item's natural size. 18 points is the tallest image a status item takes
    /// before AppKit scales it down.
    static let menuBarSize = CGSize(width: 18, height: 18)

    /// Drawn through a handler rather than rasterised once, so each scale factor renders the
    /// curves afresh instead of stretching an 18-point bitmap onto a Retina bar.
    @MainActor static let menuBarImage: NSImage = {
        let image = NSImage(size: menuBarSize, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path(in: rect.insetBy(dx: 1, dy: 1)))
            // Colour is irrelevant below: a template image keeps only the alpha channel.
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The head fitted into `rect`: aspect ratio kept, centred, and measured on the drawing's own
    /// bounds rather than the viewBox — the viewBox has wide empty margins the menu bar should
    /// not pay for in glyph size.
    static func path(in rect: CGRect) -> CGPath {
        let silhouette = leftEar()
            .union(rightEar())
            .union(head())
            .subtracting(features())

        var fit = transform(fitting: drawingBounds, into: rect)
        return silhouette.copy(using: &fit) ?? silhouette
    }

    // MARK: - Geometry (100×100 viewBox, origin top-left, y downwards)

    /// What the paths below actually occupy: ear tips at the top, chin at the bottom.
    private static let drawingBounds = CGRect(x: 22, y: 4, width: 56, height: 76)

    private static func transform(fitting source: CGRect, into target: CGRect) -> CGAffineTransform {
        let scale = min(target.width / source.width, target.height / source.height)
        return CGAffineTransform(
            translationX: target.midX - source.midX * scale,
            y: target.midY - source.midY * scale
        )
        .scaledBy(x: scale, y: scale)
    }

    private static func leftEar() -> CGPath {
        let ear = CGMutablePath()
        ear.move(to: CGPoint(x: 22, y: 46))
        ear.addLine(to: CGPoint(x: 30, y: 4))
        ear.addLine(to: CGPoint(x: 42, y: 42))
        ear.closeSubpath()
        return ear
    }

    private static func rightEar() -> CGPath {
        let ear = CGMutablePath()
        ear.move(to: CGPoint(x: 58, y: 42))
        ear.addLine(to: CGPoint(x: 70, y: 4))
        ear.addLine(to: CGPoint(x: 78, y: 46))
        ear.closeSubpath()
        return ear
    }

    private static func head() -> CGPath {
        let head = CGMutablePath()
        head.move(to: CGPoint(x: 26, y: 44))
        head.addQuadCurve(to: CGPoint(x: 34, y: 35), control: CGPoint(x: 26, y: 36))
        head.addLine(to: CGPoint(x: 66, y: 35))
        head.addQuadCurve(to: CGPoint(x: 74, y: 44), control: CGPoint(x: 74, y: 36))
        head.addLine(to: CGPoint(x: 74, y: 64))
        head.addQuadCurve(to: CGPoint(x: 62, y: 80), control: CGPoint(x: 74, y: 76))
        head.addQuadCurve(to: CGPoint(x: 38, y: 80), control: CGPoint(x: 50, y: 84))
        head.addQuadCurve(to: CGPoint(x: 26, y: 64), control: CGPoint(x: 26, y: 76))
        head.closeSubpath()
        return head
    }

    /// The two eyes and the nose, as one path to subtract from the silhouette.
    private static func features() -> CGPath {
        let features = CGMutablePath()
        features.addEllipse(in: CGRect(x: 33, y: 50, width: 8, height: 9))
        features.addEllipse(in: CGRect(x: 59, y: 50, width: 8, height: 9))
        features.move(to: CGPoint(x: 44, y: 64))
        features.addQuadCurve(to: CGPoint(x: 56, y: 64), control: CGPoint(x: 50, y: 62))
        features.addQuadCurve(to: CGPoint(x: 56, y: 70), control: CGPoint(x: 58, y: 68))
        features.addQuadCurve(to: CGPoint(x: 44, y: 70), control: CGPoint(x: 50, y: 72))
        features.addQuadCurve(to: CGPoint(x: 44, y: 64), control: CGPoint(x: 42, y: 68))
        features.closeSubpath()
        return features
    }
}
