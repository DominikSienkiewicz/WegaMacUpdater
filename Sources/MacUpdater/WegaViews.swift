import SwiftUI
import MacUpdaterCore

// MARK: - WegaHead (100×100 viewBox, animated ears)

struct WegaHead: View {
    var pose: WegaPose = .idle
    var size: CGFloat  = 100

    @State private var earL:     Double = -2
    @State private var earR:     Double =  2
    @State private var tilt:     Double =  0
    @State private var blinking: Bool   = false

    var body: some View {
        Canvas { ctx, cs in
            let s = cs.width / 100
            WegaHead.draw(ctx: ctx, s: s, earL: earL, earR: earR, pose: pose, blinking: blinking)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(tilt))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: tilt)
        .onAppear { applyPose(pose) }
        .onChange(of: pose) { _, p in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { applyPose(p) }
        }
        .task {
            while !Task.isCancelled {
                let wait = Double.random(in: 4...12)
                try? await Task.sleep(for: .seconds(wait))
                guard pose != .sleep else { continue }
                blinking = true
                try? await Task.sleep(for: .seconds(0.12))
                blinking = false
            }
        }
    }

    private func applyPose(_ p: WegaPose) {
        earL = WegaHead.earLeft(p)
        earR = WegaHead.earRight(p)
        tilt = WegaHead.headTilt(p)
    }

    static func earLeft(_ p: WegaPose) -> Double {
        switch p {
        case .idle:  return -2
        case .sniff: return -6
        case .alert: return  0
        case .happy: return -1
        case .sad:   return 28
        case .sleep: return 14
        }
    }
    static func earRight(_ p: WegaPose) -> Double {
        switch p {
        case .idle:  return  2
        case .sniff: return  6
        case .alert: return  0
        case .happy: return  1
        case .sad:   return -28
        case .sleep: return -14
        }
    }
    static func headTilt(_ p: WegaPose) -> Double {
        switch p {
        case .sniff: return  5
        case .sad:   return -3
        default:     return  0
        }
    }

    static func draw(ctx: GraphicsContext, s: CGFloat, earL: Double, earR: Double, pose: WegaPose, blinking: Bool = false) {
        // Left ear (pivot 33,44)
        var lCtx = ctx
        lCtx.translateBy(x: 33*s, y: 44*s)
        lCtx.rotate(by: .degrees(earL))
        lCtx.translateBy(x: -33*s, y: -44*s)
        lCtx.fill(leftEarOuter(s), with: .color(.wegaEarDark))
        lCtx.fill(leftEarFront(s), with: .color(.wegaBodyTan))

        // Right ear (pivot 67,44)
        var rCtx = ctx
        rCtx.translateBy(x: 67*s, y: 44*s)
        rCtx.rotate(by: .degrees(earR))
        rCtx.translateBy(x: -67*s, y: -44*s)
        rCtx.fill(rightEarOuter(s), with: .color(.wegaEarDark))
        rCtx.fill(rightEarFront(s), with: .color(.wegaBodyTan))

        // Head
        ctx.fill(headShape(s), with: .color(.wegaBodyTan))
        ctx.fill(muzzleShape(s), with: .color(Color.wegaMuzzle.opacity(0.55)))
        ctx.fill(chinShape(s),   with: .color(Color.wegaChest.opacity(0.6)))

        // Eyes
        let lw = 2.2 * s
        if pose == .sleep || blinking {
            ctx.stroke(closedEyePath(side: .left,  s: s), with: .color(.wegaFeature), lineWidth: lw)
            ctx.stroke(closedEyePath(side: .right, s: s), with: .color(.wegaFeature), lineWidth: lw)
        } else if pose == .happy {
            ctx.stroke(happyEyePath(side: .left,  s: s), with: .color(.wegaFeature), lineWidth: lw)
            ctx.stroke(happyEyePath(side: .right, s: s), with: .color(.wegaFeature), lineWidth: lw)
        } else {
            ctx.fill(eyeLiner(side: .left,  s: s), with: .color(Color.wegaFeature.opacity(0.5)))
            ctx.fill(eyeLiner(side: .right, s: s), with: .color(Color.wegaFeature.opacity(0.5)))
            ctx.fill(ellipse(40, 53, 3.1, 3.4, s), with: .color(.wegaFeature))
            ctx.fill(ellipse(60, 53, 3.1, 3.4, s), with: .color(.wegaFeature))
            let highlight = Color(red: 0.96, green: 0.85, blue: 0.66)
            ctx.fill(ellipse(41, 51.7, 1, 1, s), with: .color(highlight))
            ctx.fill(ellipse(61, 51.7, 1, 1, s), with: .color(highlight))
        }

        // Nose
        ctx.fill(noseShape(s), with: .color(.wegaFeature))
        ctx.fill(ellipse(48, 64.5, 1.3, 0.7, s), with: .color(Color.white.opacity(0.3)))

        // Mouth
        switch pose {
        case .happy:
            ctx.stroke(mouthLine(s),  with: .color(.wegaFeature), lineWidth: 1.4*s)
            ctx.stroke(happyMouth(s), with: .color(.wegaFeature), lineWidth: 1.8*s)
            ctx.fill(ellipse(50, 78, 3, 1.5, s), with: .color(.wegaTongue))
        case .sleep:
            ctx.stroke(sleepMouth(s), with: .color(.wegaFeature), lineWidth: 1.4*s)
        case .sad:
            ctx.stroke(sadMouth(s), with: .color(.wegaFeature), lineWidth: 1.6*s)
        default:
            ctx.stroke(mouthLine(s),    with: .color(.wegaFeature), lineWidth: 1.4*s)
            ctx.stroke(normalMouthL(s), with: .color(.wegaFeature), lineWidth: 1.4*s)
            ctx.stroke(normalMouthR(s), with: .color(.wegaFeature), lineWidth: 1.4*s)
        }
    }

    // MARK: Path helpers

    private static func pt(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint { CGPoint(x: x*s, y: y*s) }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ s: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: (cx-rx)*s, y: (cy-ry)*s, width: rx*2*s, height: ry*2*s))
    }

    private static func leftEarOuter(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(22,46,s)); p.addLine(to: pt(30,4,s)); p.addLine(to: pt(42,42,s)); p.closeSubpath() }
    }
    private static func leftEarFront(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(25,45,s)); p.addLine(to: pt(32,12,s)); p.addLine(to: pt(41,41,s)); p.closeSubpath() }
    }
    private static func rightEarOuter(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(58,42,s)); p.addLine(to: pt(70,4,s)); p.addLine(to: pt(78,46,s)); p.closeSubpath() }
    }
    private static func rightEarFront(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(59,41,s)); p.addLine(to: pt(68,12,s)); p.addLine(to: pt(75,45,s)); p.closeSubpath() }
    }
    private static func headShape(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: pt(26,44,s))
            p.addQuadCurve(to: pt(34,35,s), control: pt(26,36,s))
            p.addLine(to: pt(66,35,s))
            p.addQuadCurve(to: pt(74,44,s), control: pt(74,36,s))
            p.addLine(to: pt(74,64,s))
            p.addQuadCurve(to: pt(62,80,s), control: pt(74,76,s))
            p.addQuadCurve(to: pt(38,80,s), control: pt(50,84,s))
            p.addQuadCurve(to: pt(26,64,s), control: pt(26,76,s))
            p.closeSubpath()
        }
    }
    private static func muzzleShape(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: pt(36,60,s))
            p.addQuadCurve(to: pt(40,57,s), control: pt(36,58,s))
            p.addLine(to: pt(60,57,s))
            p.addQuadCurve(to: pt(64,60,s), control: pt(64,58,s))
            p.addLine(to: pt(64,70,s))
            p.addQuadCurve(to: pt(50,78,s), control: pt(62,76,s))
            p.addQuadCurve(to: pt(36,70,s), control: pt(38,76,s))
            p.closeSubpath()
        }
    }
    private static func chinShape(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: pt(42,72,s))
            p.addQuadCurve(to: pt(58,72,s), control: pt(50,78,s))
            p.addLine(to: pt(56,76,s))
            p.addQuadCurve(to: pt(44,76,s), control: pt(50,79,s))
            p.closeSubpath()
        }
    }
    private static func noseShape(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: pt(44,64,s))
            p.addQuadCurve(to: pt(56,64,s), control: pt(50,62,s))
            p.addQuadCurve(to: pt(56,70,s), control: pt(58,68,s))
            p.addQuadCurve(to: pt(44,70,s), control: pt(50,72,s))
            p.addQuadCurve(to: pt(44,64,s), control: pt(42,68,s))
            p.closeSubpath()
        }
    }

    enum Side { case left, right }

    private static func eyeLiner(side: Side, s: CGFloat) -> Path {
        switch side {
        case .left:
            Path { p in
                p.move(to: pt(33,51,s))
                p.addQuadCurve(to: pt(46,49,s), control: pt(39,48,s))
                p.addQuadCurve(to: pt(46,55,s), control: pt(47,53,s))
                p.addQuadCurve(to: pt(34,55,s), control: pt(39,57,s))
                p.closeSubpath()
            }
        case .right:
            Path { p in
                p.move(to: pt(54,49,s))
                p.addQuadCurve(to: pt(67,51,s), control: pt(61,48,s))
                p.addQuadCurve(to: pt(61,57,s), control: pt(66,55,s))
                p.addQuadCurve(to: pt(54,55,s), control: pt(54,57,s))
                p.closeSubpath()
            }
        }
    }
    private static func closedEyePath(side: Side, s: CGFloat) -> Path {
        switch side {
        case .left:  Path { p in p.move(to: pt(36,52,s)); p.addQuadCurve(to: pt(46,52,s), control: pt(41,55,s)) }
        case .right: Path { p in p.move(to: pt(54,52,s)); p.addQuadCurve(to: pt(64,52,s), control: pt(59,55,s)) }
        }
    }
    private static func happyEyePath(side: Side, s: CGFloat) -> Path {
        switch side {
        case .left:  Path { p in p.move(to: pt(36,54,s)); p.addQuadCurve(to: pt(46,54,s), control: pt(41,49,s)) }
        case .right: Path { p in p.move(to: pt(54,54,s)); p.addQuadCurve(to: pt(64,54,s), control: pt(59,49,s)) }
        }
    }
    private static func mouthLine(_ s: CGFloat)    -> Path { Path { p in p.move(to: pt(50,71,s)); p.addLine(to: pt(50,74,s)) } }
    private static func normalMouthL(_ s: CGFloat) -> Path { Path { p in p.move(to: pt(45,75,s)); p.addQuadCurve(to: pt(50,74,s), control: pt(47.5,77,s)) } }
    private static func normalMouthR(_ s: CGFloat) -> Path { Path { p in p.move(to: pt(50,74,s)); p.addQuadCurve(to: pt(55,75,s), control: pt(52.5,77,s)) } }
    private static func happyMouth(_ s: CGFloat)   -> Path { Path { p in p.move(to: pt(42,75,s)); p.addQuadCurve(to: pt(58,75,s), control: pt(50,82,s)) } }
    private static func sleepMouth(_ s: CGFloat)   -> Path { Path { p in p.move(to: pt(48,72,s)); p.addQuadCurve(to: pt(52,72,s), control: pt(50,73.5,s)) } }
    private static func sadMouth(_ s: CGFloat)     -> Path { Path { p in p.move(to: pt(44,74,s)); p.addQuadCurve(to: pt(56,74,s), control: pt(50,71,s)) } }
}

// MARK: - WegaIcon (app icon tile for sidebar brand area)

struct WegaIcon: View {
    var size: CGFloat   = 36
    var radius: CGFloat = 9

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.94, green: 0.78, blue: 0.54),
                            Color(red: 0.72, green: 0.48, blue: 0.23)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

            Canvas { ctx, cs in
                let s = cs.width / 100
                // Left ear
                ctx.fill(
                    Path { p in p.move(to: CGPoint(x: 22*s, y: 46*s)); p.addLine(to: CGPoint(x: 30*s, y: 4*s)); p.addLine(to: CGPoint(x: 42*s, y: 42*s)); p.closeSubpath() },
                    with: .color(Color(red: 0.23, green: 0.16, blue: 0.09))
                )
                // Right ear
                ctx.fill(
                    Path { p in p.move(to: CGPoint(x: 58*s, y: 42*s)); p.addLine(to: CGPoint(x: 70*s, y: 4*s)); p.addLine(to: CGPoint(x: 78*s, y: 46*s)); p.closeSubpath() },
                    with: .color(Color(red: 0.23, green: 0.16, blue: 0.09))
                )
                // Head
                ctx.fill(Path { p in
                    p.move(to: CGPoint(x: 26*s, y: 44*s))
                    p.addQuadCurve(to: CGPoint(x: 34*s, y: 35*s), control: CGPoint(x: 26*s, y: 36*s))
                    p.addLine(to: CGPoint(x: 66*s, y: 35*s))
                    p.addQuadCurve(to: CGPoint(x: 74*s, y: 44*s), control: CGPoint(x: 74*s, y: 36*s))
                    p.addLine(to: CGPoint(x: 74*s, y: 64*s))
                    p.addQuadCurve(to: CGPoint(x: 62*s, y: 80*s), control: CGPoint(x: 74*s, y: 76*s))
                    p.addQuadCurve(to: CGPoint(x: 38*s, y: 80*s), control: CGPoint(x: 50*s, y: 84*s))
                    p.addQuadCurve(to: CGPoint(x: 26*s, y: 64*s), control: CGPoint(x: 26*s, y: 76*s))
                    p.closeSubpath()
                }, with: .color(Color(red: 0.94, green: 0.85, blue: 0.71)))
                // Left eye
                ctx.fill(
                    Path(ellipseIn: CGRect(x: 33*s, y: 50*s, width: 8*s, height: 9*s)),
                    with: .color(Color(red: 0.12, green: 0.08, blue: 0.04))
                )
                // Right eye
                ctx.fill(
                    Path(ellipseIn: CGRect(x: 59*s, y: 50*s, width: 8*s, height: 9*s)),
                    with: .color(Color(red: 0.12, green: 0.08, blue: 0.04))
                )
                // Nose
                ctx.fill(Path { p in
                    p.move(to: CGPoint(x: 44*s, y: 64*s))
                    p.addQuadCurve(to: CGPoint(x: 56*s, y: 64*s), control: CGPoint(x: 50*s, y: 62*s))
                    p.addQuadCurve(to: CGPoint(x: 56*s, y: 70*s), control: CGPoint(x: 58*s, y: 68*s))
                    p.addQuadCurve(to: CGPoint(x: 44*s, y: 70*s), control: CGPoint(x: 50*s, y: 72*s))
                    p.addQuadCurve(to: CGPoint(x: 44*s, y: 64*s), control: CGPoint(x: 42*s, y: 68*s))
                    p.closeSubpath()
                }, with: .color(Color(red: 0.05, green: 0.03, blue: 0.02)))
            }
            .padding(2)
        }
        .frame(width: size, height: size)
    }
}

struct WegaSpeechBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            PawPrint(size: 10, color: Color.wegaHoney)
            Text(text)
                .font(.system(size: 11.5).italic())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
    }
}

// MARK: - Helper chip

/// M3(a) — reports the privileged helper's real `SMAppService` status instead of a
/// hard-coded green dot. Re-reads the status when the app comes back to the front, since
/// approval happens outside our process (System Settings → Login Items).
struct HelperChip: View {
    @State private var state = HelperChipState(status: PrivilegedHelperClient.shared.status)

    private var color: Color {
        switch state {
        case .active:        return .wegaSuccess
        case .needsApproval: return .wegaHoney
        case .inactive:      return .secondary
        }
    }

    private var label: String {
        switch state {
        case .active:        return tr("brew · helper aktywny")
        case .needsApproval: return tr("brew · helper wymaga zgody")
        case .inactive:      return tr("brew · helper nieaktywny")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if state.opensLoginItemsSettings { PrivilegedHelperClient.shared.openLoginItemsSettings() }
        }
        .accessibilityLabel(label)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state = HelperChipState(status: PrivilegedHelperClient.shared.status)
        }
    }
}

// MARK: - PawPrint (decorative accent icon)

struct PawPrint: View {
    var size: CGFloat  = 20
    var color: Color   = .wegaBodyTan

    var body: some View {
        Canvas { ctx, cs in
            let s = cs.width / 24
            func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx-rx)*s, y: (cy-ry)*s, width: rx*2*s, height: ry*2*s))
            }
            ctx.fill(ellipse(12,   15,  6,   5.5), with: .color(color))
            ctx.fill(ellipse(6,     9,  2.6, 3.2), with: .color(color))
            ctx.fill(ellipse(18,    9,  2.6, 3.2), with: .color(color))
            ctx.fill(ellipse(2.5,  14,  2,   2.6), with: .color(color))
            ctx.fill(ellipse(21.5, 14,  2,   2.6), with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - WegaFull (full sitting body for empty states)

struct WegaFull: View {
    var pose: WegaPose  = .idle
    var size: CGFloat   = 180
    var showBall: Bool  = false

    @State private var ballBounce = false

    var body: some View {
        ZStack {
            Canvas { ctx, cs in
                let s = cs.width / 220
                WegaFull.drawBody(ctx: ctx, s: s, pose: pose)
            }
            WegaHead(pose: pose, size: size * 0.46)
                .offset(x: 0, y: -(size * 0.5 - size * 0.46 * 0.5) + size * 0.07)

            if showBall {
                // Drop shadow
                Ellipse()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: size * 0.14, height: size * 0.03)
                    .offset(x: size * 0.24, y: size * 0.42 + (ballBounce ? size * 0.015 : 0))

                // Ball
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 1.0, green: 0.38, blue: 0.22),
                                Color(red: 0.62, green: 0.06, blue: 0.0),
                            ],
                            center: .init(x: 0.35, y: 0.28),
                            startRadius: 0,
                            endRadius: size * 0.07
                        )
                    )
                    .overlay(
                        Circle()
                            .fill(Color.white.opacity(0.25))
                            .scaleEffect(0.35)
                            .offset(x: -size * 0.02, y: -size * 0.02)
                    )
                    .frame(width: size * 0.13, height: size * 0.13)
                    .offset(x: size * 0.24, y: ballBounce ? size * 0.40 : size * 0.38)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
        }
        .frame(width: size, height: size * 200 / 220)
        .onAppear {
            guard showBall else { return }
            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                ballBounce = true
            }
        }
    }

    static func drawBody(ctx: GraphicsContext, s: CGFloat, pose _: WegaPose) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x*s, y: y*s) }
        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: (cx-rx)*s, y: (cy-ry)*s, width: rx*2*s, height: ry*2*s))
        }

        // Shadow
        ctx.fill(ellipse(110, 194, 62, 4.5), with: .color(Color.black.opacity(0.22)))

        // Tail
        let tailPath = Path { p in
            p.move(to: pt(134, 155))
            p.addQuadCurve(to: pt(168, 122), control: pt(160, 148))
            p.addQuadCurve(to: pt(162, 94),  control: pt(172, 100))
        }
        ctx.stroke(tailPath, with: .color(.wegaBodyTan), style: StrokeStyle(lineWidth: 9*s, lineCap: .round))

        // Body right shading
        ctx.fill(Path { p in
            p.move(to: pt(132, 108))
            p.addQuadCurve(to: pt(144, 168), control: pt(148, 138))
            p.addQuadCurve(to: pt(126, 178), control: pt(136, 178))
            p.addLine(to: pt(126, 110))
            p.closeSubpath()
        }, with: .color(Color.wegaBodyShade.opacity(0.5)))

        // Main body
        ctx.fill(Path { p in
            p.move(to: pt(90, 108))
            p.addQuadCurve(to: pt(100, 90), control: pt(86, 92))
            p.addLine(to: pt(122, 90))
            p.addQuadCurve(to: pt(132, 108), control: pt(134, 92))
            p.addQuadCurve(to: pt(138, 165), control: pt(142, 138))
            p.addQuadCurve(to: pt(110, 178), control: pt(132, 178))
            p.addQuadCurve(to: pt(82,  165), control: pt(88,  178))
            p.addQuadCurve(to: pt(90,  108), control: pt(78,  138))
            p.closeSubpath()
        }, with: .color(.wegaBodyTan))

        // Chest cream patch
        ctx.fill(Path { p in
            p.move(to: pt(100, 108))
            p.addQuadCurve(to: pt(120, 108), control: pt(110, 106))
            p.addLine(to: pt(119, 154))
            p.addQuadCurve(to: pt(101, 154), control: pt(110, 158))
            p.closeSubpath()
        }, with: .color(.wegaChest))

        // Front legs
        for lx: CGFloat in [92, 115] {
            ctx.fill(
                Path(roundedRect: CGRect(x: lx*s, y: 148*s, width: 13*s, height: 42*s), cornerRadius: 6*s),
                with: .color(.wegaBodyTan)
            )
            ctx.fill(
                Path(roundedRect: CGRect(x: (lx+1)*s, y: 155*s, width: 3*s, height: 32*s), cornerRadius: 1.3*s),
                with: .color(Color.wegaChest.opacity(0.5))
            )
        }
        // Paws
        for cx: CGFloat in [98.5, 121.5] {
            ctx.fill(ellipse(cx, 190, 10, 5),   with: .color(.wegaBodyShade))
            ctx.fill(ellipse(cx, 192, 5.5, 2),  with: .color(Color.wegaFeature.opacity(0.5)))
        }

        // Collar
        ctx.fill(Path { p in
            p.move(to: pt(95, 102))
            p.addQuadCurve(to: pt(125, 102), control: pt(110, 107))
            p.addLine(to: pt(125, 106))
            p.addQuadCurve(to: pt(95, 106), control: pt(110, 111))
            p.closeSubpath()
        }, with: .color(.wegaCollar))

        // Collar tag
        ctx.fill(ellipse(115, 110, 3.2, 3.2), with: .color(.wegaBodyTan))
    }
}
