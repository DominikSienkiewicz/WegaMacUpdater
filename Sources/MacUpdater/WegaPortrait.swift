import SwiftUI

/// The portrait keeps Wega's coat fixed across appearances; these are illustration colours.
enum WegaCoat {
    static let tan = Color(red: 0.78, green: 0.64, blue: 0.47)
    static let sunlitTan = Color(red: 0.87, green: 0.74, blue: 0.57)
    static let shade = Color(red: 0.63, green: 0.49, blue: 0.36)
    static let cream = Color(red: 0.95, green: 0.90, blue: 0.82)
    static let muzzle = Color(red: 0.88, green: 0.87, blue: 0.82)
    static let ear = Color(red: 0.39, green: 0.33, blue: 0.28)
    static let innerEar = Color(red: 0.64, green: 0.43, blue: 0.37)
    static let earFold = Color(red: 0.42, green: 0.27, blue: 0.23)
    static let charcoal = Color(red: 0.16, green: 0.15, blue: 0.14)
    static let iris = Color(red: 0.43, green: 0.26, blue: 0.14)
    static let nose = Color(red: 0.10, green: 0.10, blue: 0.09)
    static let collar = Color(red: 0.49, green: 0.57, blue: 0.53)
    static let buckle = Color(red: 0.74, green: 0.72, blue: 0.65)
}

/// The animated portrait and the monochrome menu-bar glyph share their silhouette.
enum WegaPortraitGeometry {
    enum Side { case left, right }

    static func ear(_ side: Side) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 30, y: 47))
        path.addCurve(to: CGPoint(x: 14, y: 26), control1: CGPoint(x: 19, y: 44), control2: CGPoint(x: 15, y: 35))
        path.addCurve(to: CGPoint(x: 14, y: 8), control1: CGPoint(x: 12, y: 18), control2: CGPoint(x: 10, y: 9))
        path.addCurve(to: CGPoint(x: 20, y: 7), control1: CGPoint(x: 15, y: 4), control2: CGPoint(x: 18, y: 4))
        path.addCurve(to: CGPoint(x: 40, y: 39), control1: CGPoint(x: 29, y: 14), control2: CGPoint(x: 36, y: 27))
        path.addQuadCurve(to: CGPoint(x: 30, y: 47), control: CGPoint(x: 40, y: 47))
        path.closeSubpath()
        return mirrored(path, side: side)
    }

    static func innerEar(_ side: Side) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 30, y: 42))
        path.addCurve(to: CGPoint(x: 17, y: 24), control1: CGPoint(x: 22, y: 38), control2: CGPoint(x: 18, y: 31))
        path.addQuadCurve(to: CGPoint(x: 17, y: 10), control: CGPoint(x: 13, y: 9))
        path.addCurve(to: CGPoint(x: 36, y: 38), control1: CGPoint(x: 23, y: 14), control2: CGPoint(x: 32, y: 27))
        path.addQuadCurve(to: CGPoint(x: 30, y: 42), control: CGPoint(x: 37, y: 44))
        path.closeSubpath()
        return mirrored(path, side: side)
    }

    static func head() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 27, y: 44))
        path.addCurve(to: CGPoint(x: 50, y: 34), control1: CGPoint(x: 29, y: 30), control2: CGPoint(x: 40, y: 32))
        path.addCurve(to: CGPoint(x: 73, y: 44), control1: CGPoint(x: 60, y: 32), control2: CGPoint(x: 71, y: 30))
        path.addCurve(to: CGPoint(x: 73, y: 66), control1: CGPoint(x: 77, y: 50), control2: CGPoint(x: 76, y: 58))
        path.addCurve(to: CGPoint(x: 50, y: 85), control1: CGPoint(x: 71, y: 80), control2: CGPoint(x: 61, y: 85))
        path.addCurve(to: CGPoint(x: 27, y: 66), control1: CGPoint(x: 39, y: 85), control2: CGPoint(x: 29, y: 80))
        path.addCurve(to: CGPoint(x: 27, y: 44), control1: CGPoint(x: 24, y: 58), control2: CGPoint(x: 23, y: 50))
        path.closeSubpath()
        return path
    }

    static func cheek(_ side: Side) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 27, y: 52))
        path.addCurve(to: CGPoint(x: 42, y: 56), control1: CGPoint(x: 30, y: 47), control2: CGPoint(x: 35, y: 53))
        path.addCurve(to: CGPoint(x: 48, y: 79), control1: CGPoint(x: 44, y: 64), control2: CGPoint(x: 50, y: 71))
        path.addCurve(to: CGPoint(x: 30, y: 70), control1: CGPoint(x: 40, y: 84), control2: CGPoint(x: 32, y: 78))
        path.addQuadCurve(to: CGPoint(x: 27, y: 52), control: CGPoint(x: 24, y: 62))
        path.closeSubpath()
        return mirrored(path, side: side)
    }

    static func brow(_ side: Side) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 29, y: 48))
        path.addCurve(to: CGPoint(x: 44, y: 47), control1: CGPoint(x: 32, y: 40), control2: CGPoint(x: 42, y: 39))
        path.addQuadCurve(to: CGPoint(x: 40, y: 52), control: CGPoint(x: 45, y: 53))
        path.addQuadCurve(to: CGPoint(x: 29, y: 48), control: CGPoint(x: 35, y: 47))
        path.closeSubpath()
        return mirrored(path, side: side)
    }

    static func eyePatch(_ side: Side) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 30, y: 49))
        path.addCurve(to: CGPoint(x: 45, y: 48), control1: CGPoint(x: 34, y: 44), control2: CGPoint(x: 41, y: 44))
        path.addCurve(to: CGPoint(x: 41, y: 57), control1: CGPoint(x: 48, y: 51), control2: CGPoint(x: 46, y: 55))
        path.addCurve(to: CGPoint(x: 30, y: 49), control1: CGPoint(x: 35, y: 57), control2: CGPoint(x: 31, y: 54))
        path.closeSubpath()
        return mirrored(path, side: side)
    }

    static func eye(_ side: Side) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 32, y: 50))
        path.addQuadCurve(to: CGPoint(x: 44, y: 50), control: CGPoint(x: 38, y: 43))
        path.addQuadCurve(to: CGPoint(x: 32, y: 50), control: CGPoint(x: 38, y: 56))
        path.closeSubpath()
        return mirrored(path, side: side)
    }

    static func muzzle() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 43, y: 56))
        path.addQuadCurve(to: CGPoint(x: 57, y: 56), control: CGPoint(x: 50, y: 51))
        path.addCurve(to: CGPoint(x: 68, y: 73), control1: CGPoint(x: 63, y: 60), control2: CGPoint(x: 70, y: 67))
        path.addCurve(to: CGPoint(x: 50, y: 81), control1: CGPoint(x: 67, y: 80), control2: CGPoint(x: 57, y: 83))
        path.addCurve(to: CGPoint(x: 32, y: 73), control1: CGPoint(x: 43, y: 83), control2: CGPoint(x: 33, y: 80))
        path.addCurve(to: CGPoint(x: 43, y: 56), control1: CGPoint(x: 30, y: 67), control2: CGPoint(x: 37, y: 60))
        path.closeSubpath()
        return path
    }

    static func nose() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 42, y: 64))
        path.addCurve(to: CGPoint(x: 58, y: 64), control1: CGPoint(x: 43, y: 59), control2: CGPoint(x: 57, y: 59))
        path.addCurve(to: CGPoint(x: 50, y: 73), control1: CGPoint(x: 61, y: 69), control2: CGPoint(x: 54, y: 73))
        path.addCurve(to: CGPoint(x: 42, y: 64), control1: CGPoint(x: 46, y: 73), control2: CGPoint(x: 39, y: 69))
        path.closeSubpath()
        return path
    }

    private static func mirrored(_ path: CGPath, side: Side) -> CGPath {
        guard side == .right else { return path }
        var transform = CGAffineTransform(translationX: 100, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &transform) ?? path
    }
}

enum WegaPortrait {
    static func draw(ctx: GraphicsContext, scale s: CGFloat, earAngles: (left: Double, right: Double), pose: WegaPose, blinking: Bool) {
        drawEar(.left, angle: earAngles.left, ctx: ctx, scale: s)
        drawEar(.right, angle: earAngles.right, ctx: ctx, scale: s)
        ctx.fill(path(WegaPortraitGeometry.head(), s), with: .linearGradient(
            Gradient(colors: [WegaCoat.sunlitTan, WegaCoat.tan]),
            startPoint: point(42, 32, s), endPoint: point(58, 84, s)
        ))
        for side in [WegaPortraitGeometry.Side.left, .right] {
            ctx.fill(path(WegaPortraitGeometry.cheek(side), s), with: .color(WegaCoat.cream))
            ctx.fill(path(WegaPortraitGeometry.brow(side), s), with: .color(WegaCoat.cream))
        }
        ctx.fill(path(WegaPortraitGeometry.muzzle(), s), with: .linearGradient(
            Gradient(colors: [WegaCoat.muzzle, WegaCoat.cream]),
            startPoint: point(50, 55, s), endPoint: point(50, 80, s)
        ))
        drawEyes(ctx: ctx, scale: s, pose: pose, blinking: blinking)
        ctx.fill(path(WegaPortraitGeometry.nose(), s), with: .color(WegaCoat.nose))
        ctx.fill(ellipse(48, 63, 3, 0.8, s), with: .color(WegaCoat.muzzle.opacity(0.35)))
        drawMouth(ctx: ctx, scale: s, pose: pose)
    }

    private static func drawEar(_ side: WegaPortraitGeometry.Side, angle: Double, ctx: GraphicsContext, scale s: CGFloat) {
        let pivotX: CGFloat = side == .left ? 31 : 69
        var earContext = ctx
        earContext.translateBy(x: pivotX*s, y: 43*s)
        earContext.rotate(by: .degrees(angle))
        earContext.translateBy(x: -pivotX*s, y: -43*s)
        let outer = path(WegaPortraitGeometry.ear(side), s)
        earContext.fill(outer, with: .color(WegaCoat.ear))
        earContext.stroke(outer, with: .color(WegaCoat.sunlitTan), lineWidth: 1.2*s)
        earContext.fill(path(WegaPortraitGeometry.innerEar(side), s), with: .linearGradient(
            Gradient(colors: [WegaCoat.ear, WegaCoat.innerEar, WegaCoat.earFold]),
            startPoint: point(pivotX, 7, s), endPoint: point(pivotX, 43, s)
        ))
    }

    private static func drawEyes(ctx: GraphicsContext, scale s: CGFloat, pose: WegaPose, blinking: Bool) {
        for side in [WegaPortraitGeometry.Side.left, .right] {
            let center: CGFloat = side == .left ? 38 : 62
            if pose == .sleep || blinking || pose == .happy {
                let lid = Path { path in
                    path.move(to: point(center - 6, 50, s))
                    path.addQuadCurve(to: point(center + 6, 50, s), control: point(center, pose == .happy && !blinking ? 44 : 56, s))
                }
                ctx.stroke(lid, with: .color(WegaCoat.charcoal), style: StrokeStyle(lineWidth: 2.5*s, lineCap: .round))
            } else {
                ctx.fill(path(WegaPortraitGeometry.eyePatch(side), s), with: .color(WegaCoat.charcoal.opacity(0.8)))
                ctx.fill(path(WegaPortraitGeometry.eye(side), s), with: .color(WegaCoat.nose))
                ctx.fill(ellipse(center, 50, 3.2, 2.8, s), with: .color(WegaCoat.iris))
                ctx.fill(ellipse(center, 49.7, 1.7, 2.2, s), with: .color(WegaCoat.nose))
                ctx.fill(ellipse(center + 0.8, 48.3, 1, 0.7, s), with: .color(WegaCoat.cream))
            }
        }
    }

    private static func drawMouth(ctx: GraphicsContext, scale s: CGFloat, pose: WegaPose) {
        let mouth = Path { path in
            switch pose {
            case .happy:
                path.move(to: point(38, 74, s))
                path.addQuadCurve(to: point(62, 74, s), control: point(50, 86, s))
            case .sleep:
                path.move(to: point(46, 77, s))
                path.addQuadCurve(to: point(54, 77, s), control: point(50, 79, s))
            case .sad:
                path.move(to: point(40, 78, s))
                path.addQuadCurve(to: point(60, 78, s), control: point(50, 73, s))
            default:
                path.move(to: point(36, 73, s))
                path.addCurve(to: point(50, 77, s), control1: point(37, 79, s), control2: point(45, 80, s))
                path.addCurve(to: point(64, 73, s), control1: point(55, 80, s), control2: point(63, 79, s))
            }
        }
        ctx.stroke(mouth, with: .color(WegaCoat.charcoal), style: StrokeStyle(lineWidth: 1.3*s, lineCap: .round))
        if pose != .sleep {
            let philtrum = Path { path in
                path.move(to: point(50, 73, s))
                path.addLine(to: point(50, 77, s))
            }
            ctx.stroke(philtrum, with: .color(WegaCoat.charcoal), lineWidth: 1.1*s)
        }
        if pose == .happy {
            ctx.fill(ellipse(50, 80, 2.5, 1.4, s), with: .color(.wegaTongue))
        }
    }

    private static func path(_ value: CGPath, _ scale: CGFloat) -> Path {
        Path(value).applying(CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func point(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: x*scale, y: y*scale)
    }

    private static func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ scale: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: (x-rx)*scale, y: (y-ry)*scale, width: 2*rx*scale, height: 2*ry*scale))
    }
}
