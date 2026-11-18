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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // UX-03 — the blink is an endless idle loop, so "Ogranicz ruch" stops it outright and
        // leaves Wega's eyes open. Keyed on the setting so flipping it takes effect at once.
        .task(id: reduceMotion) {
            guard ContinuousMotion.loopsIdleAnimations(reduceMotion: reduceMotion) else {
                blinking = false
                return
            }
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
        WegaPortrait.draw(ctx: ctx, scale: s, earAngles: (earL, earR), pose: pose, blinking: blinking)
    }
}

// MARK: - WegaIcon (app icon tile for sidebar brand area)

struct WegaIcon: View {
    var size: CGFloat   = 36
    var radius: CGFloat = 9

    var body: some View {
        Group {
            if let image = WegaBrandAsset.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(LinearGradient(
                            colors: [WegaCoat.cream, WegaCoat.sunlitTan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Canvas { ctx, cs in
                        WegaHead.draw(ctx: ctx, s: cs.width / 100, earL: 0, earR: 0, pose: .idle)
                    }
                    .padding(2)
                }
            }
        }
        .frame(width: size, height: size)
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
        chip
            .accessibilityLabel(label)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                state = HelperChipState(status: PrivilegedHelperClient.shared.status)
            }
    }

    /// UX-02 — the chip is a `Button` exactly when it does something.
    ///
    /// It used to open Login Items from a bare `onTapGesture` on an `HStack`: no button role,
    /// no keyboard path, nothing for VoiceOver to announce as actionable — a control reachable
    /// only by aiming a mouse at it, which is the class of defect this card is about.
    ///
    /// When the helper needs no approval the chip is pure status, so it stays a plain label.
    /// A disabled `Button` would still announce itself as a button and offer a tab stop that
    /// leads nowhere; saying nothing is more honest than saying "unavailable".
    @ViewBuilder
    private var chip: some View {
        if state.opensLoginItemsSettings {
            Button {
                PrivilegedHelperClient.shared.openLoginItemsSettings()
            } label: {
                indicator
            }
            .buttonStyle(.plain)
        } else {
            indicator
        }
    }

    private var indicator: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.wega(.footnote))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                WegaBall(diameter: size * 0.13)
                    .offset(x: size * 0.24, y: ballBounce ? size * 0.40 : size * 0.38)
            }
        }
        .frame(width: size, height: size * 200 / 220)
        .onAppear { updateBallBounce() }
        .onChange(of: reduceMotion) { _, _ in updateBallBounce() }
    }

    /// UX-03 — the ball rests on the ground instead of bouncing when the system asks for
    /// reduced motion, and drops back to the ground if the setting is turned on mid-bounce.
    private func updateBallBounce() {
        guard showBall else { return }
        let animation = ContinuousMotion.forever(
            .easeInOut(duration: 0.65),
            autoreverses: true,
            reduceMotion: reduceMotion
        )
        withAnimation(animation) { ballBounce = animation != nil }
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
        ctx.stroke(tailPath, with: .color(WegaCoat.tan), style: StrokeStyle(lineWidth: 9*s, lineCap: .round))

        // Body right shading
        ctx.fill(Path { p in
            p.move(to: pt(132, 108))
            p.addQuadCurve(to: pt(144, 168), control: pt(148, 138))
            p.addQuadCurve(to: pt(126, 178), control: pt(136, 178))
            p.addLine(to: pt(126, 110))
            p.closeSubpath()
        }, with: .color(WegaCoat.shade.opacity(0.5)))

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
        }, with: .color(WegaCoat.tan))

        // Chest cream patch
        ctx.fill(Path { p in
            p.move(to: pt(96, 108))
            p.addQuadCurve(to: pt(124, 108), control: pt(110, 104))
            p.addCurve(to: pt(118, 157), control1: pt(130, 129), control2: pt(123, 148))
            p.addQuadCurve(to: pt(102, 157), control: pt(110, 164))
            p.addCurve(to: pt(96, 108), control1: pt(97, 148), control2: pt(90, 129))
            p.closeSubpath()
        }, with: .color(WegaCoat.cream))

        // Front legs
        for lx: CGFloat in [92, 115] {
            ctx.fill(
                Path(roundedRect: CGRect(x: lx*s, y: 148*s, width: 13*s, height: 42*s), cornerRadius: 6*s),
                with: .color(WegaCoat.tan)
            )
            ctx.fill(
                Path(roundedRect: CGRect(x: (lx+1)*s, y: 155*s, width: 7*s, height: 32*s), cornerRadius: 1.3*s),
                with: .color(WegaCoat.cream)
            )
        }
        // Paws
        for cx: CGFloat in [98.5, 121.5] {
            ctx.fill(ellipse(cx, 190, 10, 5),   with: .color(WegaCoat.cream))
            ctx.fill(ellipse(cx, 192, 5.5, 2),  with: .color(WegaCoat.charcoal.opacity(0.5)))
        }

        // Collar
        ctx.fill(Path { p in
            p.move(to: pt(95, 102))
            p.addQuadCurve(to: pt(125, 102), control: pt(110, 107))
            p.addLine(to: pt(125, 106))
            p.addQuadCurve(to: pt(95, 106), control: pt(110, 111))
            p.closeSubpath()
        }, with: .color(WegaCoat.collar))

        // Collar buckle
        ctx.stroke(
            Path(roundedRect: CGRect(x: 117*s, y: 103*s, width: 6*s, height: 6*s), cornerRadius: 1.5*s),
            with: .color(WegaCoat.buckle), lineWidth: 1.2*s
        )
    }
}
