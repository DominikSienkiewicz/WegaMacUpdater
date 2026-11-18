import AppKit
import CoreGraphics

/// Wega's upright ears and broad muzzle, simplified to a template for the menu bar.
/// Eyes and nose are holes so they remain visible when AppKit tints the silhouette.
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
        let silhouette = WegaPortraitGeometry.ear(.left)
            .union(WegaPortraitGeometry.ear(.right))
            .union(WegaPortraitGeometry.head())
            .subtracting(features())

        var fit = transform(fitting: silhouette.boundingBoxOfPath, into: rect)
        return silhouette.copy(using: &fit) ?? silhouette
    }

    private static func transform(fitting source: CGRect, into target: CGRect) -> CGAffineTransform {
        let scale = min(target.width / source.width, target.height / source.height)
        return CGAffineTransform(
            translationX: target.midX - source.midX * scale,
            y: target.midY - source.midY * scale
        )
        .scaledBy(x: scale, y: scale)
    }

    private static func features() -> CGPath {
        let features = CGMutablePath()
        features.addPath(WegaPortraitGeometry.eye(.left))
        features.addPath(WegaPortraitGeometry.eye(.right))
        features.addPath(WegaPortraitGeometry.nose())
        return features
    }
}
