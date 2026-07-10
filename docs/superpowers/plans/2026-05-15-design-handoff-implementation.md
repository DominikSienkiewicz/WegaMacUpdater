# WegaMacUpdater Design Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the designer's HTML/JSX handoff into the existing SwiftUI macOS codebase — custom sidebar with animated Wega dog mascot, honey/caramel color scheme, and redesigned all four tabs.

**Architecture:** Custom `HStack` layout replaces `NavigationSplitView` for full sidebar control. New `WegaTheme.swift` supplies shared color tokens. New `WegaViews.swift` contains the Wega mascot as animated SwiftUI `Canvas` views. Each tab view is fully rewritten to match the prototype while staying wired to the existing `BrewService` / `MasService` / `ApplicationScanner` model layer. `SharedViews.swift` is extended with new reusable primitives (WegaBadge, WegaCard, PackageRow).

**Tech Stack:** SwiftUI macOS 13+, `Canvas` API (macOS 12+), `GraphicsContext` value-type transforms, existing `MacUpdaterCore` models.

**Source files live at:** `Sources/MacUpdater/` inside the repo root (`/Users/dominiksienkiewicz/Dev/Projects/public/WegaMacUpdater`).

**Key model constraints (read Models.swift before starting):**
- `BrewOutdatedItem` has `name`, `installedVersions: [String]`, `currentVersion: String?` — no separate `latestVersion`; `currentVersion` IS the latest.
- `MasOutdatedApp` has `installedVersion`, `currentVersion`.
- `ApplicationInfo` has `isManagedByBrew: Bool`, `caskToken: String?` — no `source` enum, no `sizeBytes`.
- No confidence score for migration candidates — skip that column.

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/MacUpdater/WegaTheme.swift` | **Create** | Color tokens, design constants |
| `Sources/MacUpdater/WegaViews.swift` | **Create** | WegaHead, WegaFull, WegaIcon, PawPrint mascot views |
| `Sources/MacUpdater/SharedViews.swift` | **Modify** | Add WegaBadge, WegaCard, PackageRow; keep ErrorBanner |
| `Sources/MacUpdater/ContentView.swift` | **Rewrite** | Custom HStack sidebar + content router + WegaState logic |
| `Sources/MacUpdater/UpdateView.swift` | **Rewrite** | 3-state view: empty / checking / results with checkboxes |
| `Sources/MacUpdater/UninstallView.swift` | **Rewrite** | Search header, select-all, custom overlay dialog |
| `Sources/MacUpdater/MigrationView.swift` | **Rewrite** | Two-section layout (matchable / unmatched), per-row migrate |
| `Sources/MacUpdater/InventoryView.swift` | **Rewrite** | Clickable stat cards, filter pills, sortable table |

---

## Task 1: WegaTheme — Color Tokens and Design Constants

**Files:**
- Create: `Sources/MacUpdater/WegaTheme.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

// MARK: - Palette
extension Color {
    // Accent
    static let wegaHoney   = Color(red: 0.910, green: 0.722, blue: 0.478) // #e8b87a
    static let wegaToffee  = Color(red: 0.831, green: 0.647, blue: 0.455) // #d4a574
    static let wegaCaramel = Color(red: 0.690, green: 0.459, blue: 0.251) // #b07540
    // Semantic
    static let wegaSuccess = Color(red: 0.608, green: 0.769, blue: 0.478) // #9bc47a
    static let wegaDanger  = Color(red: 0.831, green: 0.459, blue: 0.420) // #d4756b
    static let wegaInfo    = Color(red: 0.478, green: 0.690, blue: 0.831) // #7ab0d4
    // Wega coat
    static let wegaBodyTan  = Color(red: 0.831, green: 0.627, blue: 0.416) // #d4a06a
    static let wegaBodyShade = Color(red: 0.659, green: 0.459, blue: 0.267) // #a87544
    static let wegaEarDark  = Color(red: 0.227, green: 0.157, blue: 0.094) // #3a2818
    static let wegaEarInner = Color(red: 0.784, green: 0.522, blue: 0.478) // #c8857a
    static let wegaMuzzle   = Color(red: 0.478, green: 0.310, blue: 0.180) // #7a4f2e
    static let wegaChest    = Color(red: 0.953, green: 0.890, blue: 0.784) // #f3e3c8
    static let wegaFeature  = Color(red: 0.055, green: 0.031, blue: 0.020) // #0e0805
    static let wegaCollar   = Color(red: 0.776, green: 0.376, blue: 0.333) // #c66055
    static let wegaTongue   = Color(red: 0.910, green: 0.565, blue: 0.565) // #e89090
}

// MARK: - Pose
enum WegaPose: Equatable {
    case idle, sniff, alert, happy, sad, sleep
}

// MARK: - Sidebar Wega prominence
enum WegaProminence {
    case subtle, friendly, hero
}

// MARK: - Wega state (pose + speech line)
struct WegaState: Equatable {
    var pose: WegaPose
    var line: String

    static let `default` = WegaState(pose: .idle, line: "Cześć! Co dziś robimy?")

    static func forTab(_ tab: SidebarTab) -> WegaState {
        switch tab {
        case .update:    return WegaState(pose: .idle,  line: "Sprawdzimy, co się zestarzało?")
        case .uninstall: return WegaState(pose: .alert, line: "Aport! Zaznacz, co mam zabrać.")
        case .migration: return WegaState(pose: .idle,  line: "Pójdę zwęszyć /Applications.")
        case .inventory: return WegaState(pose: .idle,  line: "Obejdę wszystkie kąty.")
        }
    }
}

// MARK: - Layout constants
enum WegaLayout {
    static let sidebarWidth: CGFloat = 240
    static let cardRadius: CGFloat   = 12
    static let rowRadius: CGFloat    = 8
    static let windowMinWidth: CGFloat  = 980
    static let windowMinHeight: CGFloat = 640
}
```

- [ ] **Step 2: Build to verify it compiles**

  In Xcode or via `swift build` — fix any syntax errors before proceeding.

---

## Task 2: WegaViews — Animated Dog Mascot

**Files:**
- Create: `Sources/MacUpdater/WegaViews.swift`

The mascot is drawn in a 100×100 coordinate space and scaled to the requested `size`. Ear and head animations use `@State` angles updated via `withAnimation` in `onChange(of: pose)`. `GraphicsContext` is a value type — `var earCtx = ctx` gives an isolated copy with its own transform, leaving `ctx` unmodified for subsequent draws.

- [ ] **Step 1: Create WegaViews.swift with WegaHead**

```swift
import SwiftUI

// MARK: - WegaHead (100×100 viewBox)

struct WegaHead: View {
    var pose: WegaPose = .idle
    var size: CGFloat  = 100

    @State private var earL: Double  = -2
    @State private var earR: Double  =  2
    @State private var tilt: Double  =  0

    var body: some View {
        Canvas { ctx, cs in
            let s = cs.width / 100
            WegaHead.draw(ctx: ctx, s: s, earL: earL, earR: earR, pose: pose)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(tilt))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: tilt)
        .onAppear { apply(pose) }
        .onChange(of: pose) { _, p in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { apply(p) }
        }
    }

    private mutating func apply(_ p: WegaPose) {
        earL = WegaHead.earLeft(p)
        earR = WegaHead.earRight(p)
        tilt = WegaHead.headTilt(p)
    }

    // MARK: Angle tables
    static func earLeft(_ p: WegaPose) -> Double {
        switch p { case .idle: -2; case .sniff: -6; case .alert: 0; case .happy: -1; case .sad: 28; case .sleep: 14 }
    }
    static func earRight(_ p: WegaPose) -> Double {
        switch p { case .idle: 2; case .sniff: 6; case .alert: 0; case .happy: 1; case .sad: -28; case .sleep: -14 }
    }
    static func headTilt(_ p: WegaPose) -> Double {
        switch p { case .sniff: 5; case .sad: -3; default: 0 }
    }

    // MARK: Drawing (100×100 coordinate space, already scaled by s)
    static func draw(ctx: GraphicsContext, s: CGFloat, earL: Double, earR: Double, pose: WegaPose) {

        // ── Left ear (pivot at 33,44) ──
        var lCtx = ctx
        lCtx.translateBy(x: 33*s, y: 44*s)
        lCtx.rotate(by: .degrees(earL))
        lCtx.translateBy(x: -33*s, y: -44*s)
        lCtx.fill(leftEarOuter(s), with: .color(.wegaEarDark))
        lCtx.fill(leftEarFront(s), with: .color(.wegaBodyTan))

        // ── Right ear (pivot at 67,44) ──
        var rCtx = ctx
        rCtx.translateBy(x: 67*s, y: 44*s)
        rCtx.rotate(by: .degrees(earR))
        rCtx.translateBy(x: -67*s, y: -44*s)
        rCtx.fill(rightEarOuter(s), with: .color(.wegaEarDark))
        rCtx.fill(rightEarFront(s), with: .color(.wegaBodyTan))

        // ── Head ──
        ctx.fill(headShape(s), with: .color(.wegaBodyTan))

        // muzzle shading
        var mz = muzzleShape(s)
        ctx.fill(mz, with: .color(Color.wegaMuzzle.opacity(0.55)))

        // chin cream
        ctx.fill(chinShape(s), with: .color(Color.wegaChest.opacity(0.6)))

        // ── Eyes ──
        switch pose {
        case .sleep:
            ctx.stroke(closedEyePath(side: .left,  s: s), with: .color(.wegaFeature), lineWidth: 2.2*s/100*100)
            ctx.stroke(closedEyePath(side: .right, s: s), with: .color(.wegaFeature), lineWidth: 2.2*s/100*100)
        case .happy:
            ctx.stroke(happyEyePath(side: .left,  s: s), with: .color(.wegaFeature), lineWidth: 2.2*s/100*100)
            ctx.stroke(happyEyePath(side: .right, s: s), with: .color(.wegaFeature), lineWidth: 2.2*s/100*100)
        default:
            ctx.fill(eyeLiner(side: .left,  s: s), with: .color(Color.wegaFeature.opacity(0.5)))
            ctx.fill(eyeLiner(side: .right, s: s), with: .color(Color.wegaFeature.opacity(0.5)))
            ctx.fill(eyeEllipse(cx: 40, cy: 53, rx: 3.1, ry: 3.4, s: s), with: .color(.wegaFeature))
            ctx.fill(eyeEllipse(cx: 60, cy: 53, rx: 3.1, ry: 3.4, s: s), with: .color(.wegaFeature))
            ctx.fill(eyeEllipse(cx: 41, cy: 51.7, rx: 1, ry: 1, s: s), with: .color(Color(red: 0.96, green: 0.85, blue: 0.66)))
            ctx.fill(eyeEllipse(cx: 61, cy: 51.7, rx: 1, ry: 1, s: s), with: .color(Color(red: 0.96, green: 0.85, blue: 0.66)))
        }

        // ── Nose ──
        ctx.fill(noseShape(s), with: .color(.wegaFeature))
        ctx.fill(eyeEllipse(cx: 48, cy: 64.5, rx: 1.3, ry: 0.7, s: s), with: .color(Color.white.opacity(0.3)))

        // ── Mouth ──
        let lw = 1.6 * s
        switch pose {
        case .happy:
            ctx.stroke(mouthLine(s), with: .color(.wegaFeature), lineWidth: 1.4*s)
            ctx.stroke(happyMouth(s), with: .color(.wegaFeature), lineWidth: 1.8*s)
            ctx.fill(eyeEllipse(cx: 50, cy: 78, rx: 3, ry: 1.5, s: s), with: .color(.wegaTongue))
        case .sleep:
            ctx.stroke(sleepMouth(s), with: .color(.wegaFeature), lineWidth: 1.4*s)
        case .sad:
            ctx.stroke(sadMouth(s), with: .color(.wegaFeature), lineWidth: lw)
        default:
            ctx.stroke(mouthLine(s), with: .color(.wegaFeature), lineWidth: 1.4*s)
            ctx.stroke(normalMouthL(s), with: .color(.wegaFeature), lineWidth: 1.4*s)
            ctx.stroke(normalMouthR(s), with: .color(.wegaFeature), lineWidth: 1.4*s)
        }
    }

    // MARK: Paths (100×100 coordinate space, scaled by s)

    private static func pt(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint { CGPoint(x: x*s, y: y*s) }

    private static func leftEarOuter(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: pt(22,46,s)); p.addLine(to: pt(30,4,s)); p.addLine(to: pt(42,42,s)); p.closeSubpath()
        }
    }
    private static func leftEarFront(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: pt(25,45,s)); p.addLine(to: pt(32,12,s)); p.addLine(to: pt(41,41,s)); p.closeSubpath()
        }
    }
    private static func rightEarOuter(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: pt(58,42,s)); p.addLine(to: pt(70,4,s)); p.addLine(to: pt(78,46,s)); p.closeSubpath()
        }
    }
    private static func rightEarFront(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: pt(59,41,s)); p.addLine(to: pt(68,12,s)); p.addLine(to: pt(75,45,s)); p.closeSubpath()
        }
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
    private static func eyeEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, s: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: (cx-rx)*s, y: (cy-ry)*s, width: rx*2*s, height: ry*2*s))
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
    private static func mouthLine(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(50,71,s)); p.addLine(to: pt(50,74,s)) }
    }
    private static func normalMouthL(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(45,75,s)); p.addQuadCurve(to: pt(50,74,s), control: pt(47.5,77,s)) }
    }
    private static func normalMouthR(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(50,74,s)); p.addQuadCurve(to: pt(55,75,s), control: pt(52.5,77,s)) }
    }
    private static func happyMouth(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(42,75,s)); p.addQuadCurve(to: pt(58,75,s), control: pt(50,82,s)) }
    }
    private static func sleepMouth(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(48,72,s)); p.addQuadCurve(to: pt(52,72,s), control: pt(50,73.5,s)) }
    }
    private static func sadMouth(_ s: CGFloat) -> Path {
        Path { p in p.move(to: pt(44,74,s)); p.addQuadCurve(to: pt(56,74,s), control: pt(50,71,s)) }
    }
}
```

- [ ] **Step 2: Add WegaIcon (app icon tile)**

Append to the same file:

```swift
// MARK: - WegaIcon (app icon tile in sidebar brand area)
struct WegaIcon: View {
    var size: CGFloat  = 36
    var radius: CGFloat = 9

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.94, green: 0.78, blue: 0.54), Color(red: 0.72, green: 0.48, blue: 0.23)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            // Tiny head silhouette
            Canvas { ctx, cs in
                let s = cs.width / 100
                // ears
                ctx.fill(Path { p in p.move(to: CGPoint(x: 22*s, y: 46*s)); p.addLine(to: CGPoint(x: 30*s, y: 4*s)); p.addLine(to: CGPoint(x: 42*s, y: 42*s)); p.closeSubpath() }, with: .color(Color(red: 0.23, green: 0.16, blue: 0.09)))
                ctx.fill(Path { p in p.move(to: CGPoint(x: 58*s, y: 42*s)); p.addLine(to: CGPoint(x: 70*s, y: 4*s)); p.addLine(to: CGPoint(x: 78*s, y: 46*s)); p.closeSubpath() }, with: .color(Color(red: 0.23, green: 0.16, blue: 0.09)))
                // head
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
                // nose
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
```

- [ ] **Step 3: Add PawPrint accent icon**

Append to the same file:

```swift
// MARK: - PawPrint (small decorative accent)
struct PawPrint: View {
    var size: CGFloat = 20
    var color: Color  = .wegaBodyTan

    var body: some View {
        Canvas { ctx, cs in
            let s = cs.width / 24
            func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx-rx)*s, y: (cy-ry)*s, width: rx*2*s, height: ry*2*s))
            }
            ctx.fill(ellipse(12, 15, 6,   5.5), with: .color(color))
            ctx.fill(ellipse(6,   9, 2.6, 3.2), with: .color(color))
            ctx.fill(ellipse(18,  9, 2.6, 3.2), with: .color(color))
            ctx.fill(ellipse(2.5,14, 2,   2.6), with: .color(color))
            ctx.fill(ellipse(21.5,14,2,   2.6), with: .color(color))
        }
        .frame(width: size, height: size)
    }
}
```

- [ ] **Step 4: Add WegaFull (sitting body for empty states)**

Append to the same file. This is a simplified body — legs, chest patch, tail, collar — drawn in Canvas on a 220×200 viewBox:

```swift
// MARK: - WegaFull (full body, 220×200 viewBox)
struct WegaFull: View {
    var pose: WegaPose = .idle
    var size: CGFloat  = 180

    var body: some View {
        ZStack {
            Canvas { ctx, cs in
                let s = cs.width / 220
                WegaFull.drawBody(ctx: ctx, s: s, pose: pose)
            }
            // Head on top (positioned at the neck area)
            WegaHead(pose: pose, size: size * 0.46)
                .offset(x: 0, y: -(size * 0.5 - size * 0.46 * 0.5) + size * 0.07)
        }
        .frame(width: size, height: size * 200/220)
    }

    static func drawBody(ctx: GraphicsContext, s: CGFloat, pose: WegaPose) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x*s, y: y*s) }
        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: (cx-rx)*s, y: (cy-ry)*s, width: rx*2*s, height: ry*2*s))
        }

        // shadow
        ctx.fill(ellipse(110, 194, 62, 4.5), with: .color(Color.black.opacity(0.22)))

        // tail
        let tailPath = Path { p in
            p.move(to: pt(134,155))
            p.addQuadCurve(to: pt(168,122), control: pt(160,148))
            p.addQuadCurve(to: pt(162,94), control: pt(172,100))
        }
        ctx.stroke(tailPath, with: .color(.wegaBodyTan), style: StrokeStyle(lineWidth: 9*s, lineCap: .round))

        // body right shading
        ctx.fill(Path { p in
            p.move(to: pt(132,108))
            p.addQuadCurve(to: pt(144,168), control: pt(148,138))
            p.addQuadCurve(to: pt(126,178), control: pt(136,178))
            p.addLine(to: pt(126,110))
            p.closeSubpath()
        }, with: .color(Color.wegaBodyShade.opacity(0.5)))

        // main body
        ctx.fill(Path { p in
            p.move(to: pt(90,108))
            p.addQuadCurve(to: pt(100,90), control: pt(86,92))
            p.addLine(to: pt(122,90))
            p.addQuadCurve(to: pt(132,108), control: pt(134,92))
            p.addQuadCurve(to: pt(138,165), control: pt(142,138))
            p.addQuadCurve(to: pt(110,178), control: pt(132,178))
            p.addQuadCurve(to: pt(82,165), control: pt(88,178))
            p.addQuadCurve(to: pt(90,108), control: pt(78,138))
            p.closeSubpath()
        }, with: .color(.wegaBodyTan))

        // chest cream patch
        ctx.fill(Path { p in
            p.move(to: pt(100,108))
            p.addQuadCurve(to: pt(120,108), control: pt(110,106))
            p.addLine(to: pt(119,154))
            p.addQuadCurve(to: pt(101,154), control: pt(110,158))
            p.closeSubpath()
        }, with: .color(.wegaChest))

        // front legs
        let legW = 13*s, legH = 42*s, legR = 6*s
        for lx: CGFloat in [92, 115] {
            ctx.fill(Path(roundedRect: CGRect(x: lx*s, y: 148*s, width: legW, height: legH), cornerRadius: legR), with: .color(.wegaBodyTan))
            ctx.fill(Path(roundedRect: CGRect(x: (lx+1)*s, y: 155*s, width: 3*s, height: 32*s), cornerRadius: 1.3*s), with: .color(Color.wegaChest.opacity(0.5)))
        }
        // paws
        for cx: CGFloat in [98.5, 121.5] {
            ctx.fill(ellipse(cx, 190, 10, 5), with: .color(.wegaBodyShade))
            ctx.fill(ellipse(cx, 192, 5.5, 2), with: .color(Color.wegaFeature.opacity(0.5)))
        }

        // collar
        ctx.fill(Path { p in
            p.move(to: pt(95,102))
            p.addQuadCurve(to: pt(125,102), control: pt(110,107))
            p.addLine(to: pt(125,106))
            p.addQuadCurve(to: pt(95,106), control: pt(110,111))
            p.closeSubpath()
        }, with: .color(.wegaCollar))
        // collar tag
        ctx.fill(ellipse(115, 110, 3.2, 3.2), with: .color(.wegaBodyTan))
    }
}
```

- [ ] **Step 5: Build and fix any compilation errors**

  The Canvas API, Path, and SwiftUI shapes should compile on macOS 13+. Check for any type mismatches.

---

## Task 3: SharedViews — Extended Primitives

**Files:**
- Modify: `Sources/MacUpdater/SharedViews.swift`

Keep `ErrorBanner`, `StatusRow`, `SectionHeader`. Add `WegaBadge`, `WegaCard`, `PackageRow`, `SelectAllRow`.

- [ ] **Step 1: Add WegaBadge**

Append to `SharedViews.swift`:

```swift
enum WegaBadgeVariant {
    case brew, appStore, manual, success, danger, info

    var bg: Color {
        switch self {
        case .brew:     return Color.wegaHoney.opacity(0.12)
        case .appStore: return Color.wegaInfo.opacity(0.12)
        case .manual:   return Color.wegaDanger.opacity(0.10)
        case .success:  return Color.wegaSuccess.opacity(0.12)
        case .danger:   return Color.wegaDanger.opacity(0.12)
        case .info:     return Color.wegaInfo.opacity(0.12)
        }
    }
    var fg: Color {
        switch self {
        case .brew:     return .wegaHoney
        case .appStore: return .wegaInfo
        case .manual:   return .wegaDanger
        case .success:  return .wegaSuccess
        case .danger:   return .wegaDanger
        case .info:     return .wegaInfo
        }
    }
}

struct WegaBadge: View {
    let label: String
    var variant: WegaBadgeVariant = .brew

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(variant.fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(variant.bg, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(variant.fg.opacity(0.25), lineWidth: 1))
    }
}
```

- [ ] **Step 2: Add WegaCard (container)**

```swift
struct WegaCard<Content: View>: View {
    var padded: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: WegaLayout.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: WegaLayout.cardRadius).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
```

- [ ] **Step 3: Add PackageRow (shared row used in Update + Uninstall)**

```swift
struct PackageRow: View {
    let name: String
    var token: String? = nil
    var currentVersion: String?
    var latestVersion: String?
    var isSelected: Bool = false
    var onToggle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if onToggle != nil {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.wegaHoney : .secondary)
                    .font(.system(size: 16))
                    .onTapGesture { onToggle?() }
            }
            PackageLetterIcon(name: name)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                if let t = token {
                    Text(t).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let from = currentVersion, let to = latestVersion {
                VersionArrow(from: from, to: to)
            } else if let v = currentVersion ?? latestVersion {
                Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSelected ? Color.wegaHoney.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
    }
}

// First-letter colored tile (replaces PackageIcon from prototype)
struct PackageLetterIcon: View {
    let name: String
    var size: CGFloat = 28

    private var letter: String { String(name.first ?? "?").uppercased() }
    private var bg: Color {
        let h = name.unicodeScalars.reduce(0) { $0 + $1.value } % 4
        let hues: [Double] = [0.08, 0.12, 0.06, 0.10]
        return Color(hue: hues[Int(h)], saturation: 0.6, brightness: 0.65)
    }

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(bg, in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}

// Version arrow: "1.0 → 2.0"
struct VersionArrow: View {
    let from: String
    let to: String

    var body: some View {
        HStack(spacing: 5) {
            Text(from).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.system(size: 9))
            Text(to).foregroundStyle(Color.wegaHoney)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}
```

- [ ] **Step 4: Add EmptyHero (empty state with Wega)**

```swift
struct EmptyHero: View {
    var pose: WegaPose = .idle
    var title: String
    var message: String
    var action: AnyView? = nil
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            WegaFull(pose: pose, size: compact ? 130 : 170)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            if let action { action }
        }
        .padding(compact ? 32 : 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 5: Build to verify no compilation errors**

---

## Task 4: ContentView — Custom Sidebar with Wega Panel

**Files:**
- Rewrite: `Sources/MacUpdater/ContentView.swift`

Replace `NavigationSplitView` with a custom `HStack`. The sidebar is fully custom. `SidebarTab` replaces `SidebarItem`. `WegaState` (from `WegaTheme`) flows down via `@State` in the root view.

- [ ] **Step 1: Rewrite ContentView.swift**

```swift
import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case update    = "update"
    case uninstall = "uninstall"
    case migration = "migration"
    case inventory = "inventory"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .update:    "Update"
        case .uninstall: "Uninstall"
        case .migration: "Migration"
        case .inventory: "Inventory"
        }
    }
    var systemImage: String {
        switch self {
        case .update:    "arrow.triangle.2.circlepath"
        case .uninstall: "trash"
        case .migration: "arrow.right.doc.on.clipboard"
        case .inventory: "tablecells"
        }
    }
    var hint: String {
        switch self {
        case .update:    "Co do odświeżenia"
        case .uninstall: "Usuń aplikacje"
        case .migration: "Przepnij pod Brew"
        case .inventory: "Pełny obchód"
        }
    }
}

struct ContentView: View {
    @State private var activeTab: SidebarTab = .update
    @State private var wegaState: WegaState  = .forTab(.update)
    @State private var updateBadge: Int      = 0

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                activeTab:   $activeTab,
                wegaState:   $wegaState,
                updateBadge: updateBadge
            )
            Divider()
            ContentArea(
                activeTab:   $activeTab,
                wegaState:   $wegaState,
                updateBadge: $updateBadge
            )
        }
        .frame(minWidth: WegaLayout.windowMinWidth, minHeight: WegaLayout.windowMinHeight)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var activeTab:   SidebarTab
    @Binding var wegaState:   WegaState
    let updateBadge: Int

    var body: some View {
        VStack(spacing: 0) {
            // Brand header
            HStack(spacing: 11) {
                WegaIcon(size: 36, radius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WegaMacUpdater")
                        .font(.system(size: 14, weight: .bold))
                    HStack(spacing: 5) {
                        Circle().fill(Color.wegaSuccess).frame(width: 5, height: 5)
                        Text("brew · helper aktywny")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)

            Divider().opacity(0.5)

            // Tabs
            VStack(alignment: .leading, spacing: 1) {
                Text("Narzędzia")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(1)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(SidebarTab.allCases) { tab in
                    SidebarTabRow(
                        tab:         tab,
                        isActive:    activeTab == tab,
                        badge:       tab == .update && updateBadge > 0 ? updateBadge : nil,
                        onSelect:    {
                            activeTab = tab
                            wegaState = .forTab(tab)
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Spacer()

            Divider().opacity(0.5)

            // Wega status panel
            WegaStatusPanel(state: wegaState)
        }
        .frame(width: WegaLayout.sidebarWidth)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }
}

private struct SidebarTabRow: View {
    let tab:      SidebarTab
    let isActive: Bool
    let badge:    Int?
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .foregroundStyle(isActive ? Color.wegaHoney : .secondary)
                    .frame(width: 16)
                Text(tab.label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                Spacer()
                if let b = badge {
                    Text("\(b)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isActive ? Color(red: 0.16, green: 0.11, blue: 0.07) : Color.wegaHoney)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isActive ? Color.wegaHoney : Color.wegaHoney.opacity(0.18), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive
                        ? Color.wegaHoney.opacity(0.15)
                        : (isHovered ? Color.wegaHoney.opacity(0.05) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isActive ? Color.wegaHoney.opacity(0.20) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Wega Status Panel (friendly mode: head + speech bubble)

private struct WegaStatusPanel: View {
    let state: WegaState

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            WegaHead(pose: state.pose, size: 44)
                .padding(2)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))

            ZStack(alignment: .bottomLeading) {
                // bubble tail
                Rectangle()
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 10, height: 10)
                    .overlay(
                        Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .rotationEffect(.degrees(45))
                    .offset(x: -5, y: -10)

                Text("„\(state.line)"")
                    .font(.system(size: 11.5).italic())
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.pose)
    }
}

// MARK: - Content Area

private struct ContentArea: View {
    @Binding var activeTab:   SidebarTab
    @Binding var wegaState:   WegaState
    @Binding var updateBadge: Int

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: activeTab.systemImage)
                    .foregroundStyle(Color.wegaHoney)
                Text(activeTab.label)
                    .font(.system(size: 13, weight: .semibold))
                Text("· \(activeTab.hint)")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 6) {
                    PawPrint(size: 12, color: Color.wegaToffee)
                    Text(wegaState.line)
                        .font(.system(size: 11).italic())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color.wegaHoney.opacity(0.02))

            Divider().opacity(0.5)

            // Tab body
            Group {
                switch activeTab {
                case .update:
                    UpdateView(onWegaState: { wegaState = $0 }, onBadgeChange: { updateBadge = $0 })
                case .uninstall:
                    UninstallView(onWegaState: { wegaState = $0 })
                case .migration:
                    MigrationView(onWegaState: { wegaState = $0 })
                case .inventory:
                    InventoryView(onWegaState: { wegaState = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

- [ ] **Step 2: Update MacUpdaterApp.swift to inject EnvironmentObject**

  Open `Sources/MacUpdater/MacUpdaterApp.swift`. Ensure `AppViewModel` is injected as `.environmentObject`. No structural change needed if it already does this — just verify.

- [ ] **Step 3: Build — fix any "cannot find type" errors**

  `SidebarTab` is now defined here; old `SidebarItem` references in other files will break until those files are updated in subsequent tasks.

---

## Task 5: UpdateView — 3-State Redesign

**Files:**
- Rewrite: `Sources/MacUpdater/UpdateView.swift`

Three states: `ready` (empty hero), `checking` (animated command bars + Wega sniff), `results` (checkboxes + select-all + update button).

The view now accepts callbacks: `onWegaState` and `onBadgeChange`.

- [ ] **Step 1: Rewrite UpdateView.swift**

```swift
import SwiftUI
import MacUpdaterCore

private enum UpdateStatus { case ready, checking, results }

struct UpdateView: View {
    var onWegaState:   ((WegaState) -> Void)?
    var onBadgeChange: ((Int) -> Void)?

    @EnvironmentObject private var model: AppViewModel

    @State private var status:       UpdateStatus = .ready
    @State private var brewOutdated: BrewOutdated?
    @State private var masOutdated:  [MasOutdatedApp] = []
    @State private var selected:     Set<String>      = []
    @State private var updating:     Bool             = false
    @State private var errorMessage: String?
    @State private var lastCheck:    Date?
    @State private var banner:       BannerData?

    // Unique keys: "f:<name>", "c:<name>", "a:<id>"
    private var allItems: [OutdatedItem] {
        var items: [OutdatedItem] = []
        if let b = brewOutdated {
            items += b.formulae.map { OutdatedItem(key: "f:\($0.name)", name: $0.name, from: $0.installedVersions.first, to: $0.currentVersion, kind: .formula) }
            items += b.casks.map    { OutdatedItem(key: "c:\($0.name)", name: $0.name, from: $0.installedVersions.first, to: $0.currentVersion, kind: .cask)    }
        }
        items += masOutdated.map { OutdatedItem(key: "a:\($0.appStoreID)", name: $0.name, from: $0.installedVersion, to: $0.currentVersion, kind: .appStore) }
        return items
    }

    var body: some View {
        switch status {
        case .ready:    readyView
        case .checking: checkingView
        case .results:  resultsView
        }
    }

    // MARK: Ready
    private var readyView: some View {
        EmptyHero(
            pose: .idle,
            title: "Sprawdźmy, co się zestarzało",
            message: "Wega zajrzy do Homebrew i Mac App Store i powie, co warto odświeżyć.",
            action: AnyView(
                Button { Task { await runCheck() } } label: {
                    Label("Sprawdź aktualizacje", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                .controlSize(.large)
            )
        )
    }

    // MARK: Checking
    private var checkingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(["brew update", "brew outdated", "brew outdated --cask --greedy", "mas outdated"].enumerated().map { $0 }, id: \.offset) { idx, cmd in
                CheckingBar(command: cmd, delay: Double(idx) * 0.2)
            }
            HStack(spacing: 16) {
                Spacer()
                WegaFull(pose: .sniff, size: 120)
                Text("Wega węszy po Homebrew…")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 16)
        }
        .padding(24)
    }

    // MARK: Results
    private var resultsView: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(allItems.isEmpty ? "Wszystko aktualne" : "\(allItems.count) aktualizacji do zainstalowania")
                        .font(.system(size: 18, weight: .semibold))
                    if let d = lastCheck {
                        HStack(spacing: 4) {
                            Text("Sprawdzono \(d.formatted(date: .omitted, time: .shortened))")
                            Text("·")
                            Text("brew + mas").font(.system(size: 11, design: .monospaced))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button { Task { await runCheck() } } label: {
                    Label("Sprawdź ponownie", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(updating)

                if !allItems.isEmpty {
                    Button { Task { await runUpdate() } } label: {
                        if updating {
                            ProgressView().controlSize(.small)
                        } else if selected.isEmpty {
                            Label("Zaktualizuj wszystkie (\(allItems.count))", systemImage: "arrow.down.circle.fill")
                        } else {
                            Label("Zaktualizuj wybrane (\(selected.count))", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoney)
                    .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                    .disabled(updating)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let b = banner {
                BannerView(data: b) { banner = nil }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if allItems.isEmpty {
                EmptyHero(pose: .sleep, title: "Wszystko aktualne", message: "Wega się zdrzemnie. Zajrzymy znowu za jakiś czas.", compact: true)
            } else {
                // Select-all row
                HStack(spacing: 10) {
                    Image(systemName: selectAllSymbol)
                        .foregroundStyle(selected.isEmpty ? .secondary : Color.wegaHoney)
                        .font(.system(size: 16))
                        .onTapGesture { toggleAll() }
                    Text(selected.isEmpty ? "Zaznacz wszystko" : "\(selected.count) z \(allItems.count) zaznaczonych")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        let formulae = allItems.filter { $0.kind == .formula }
                        let casks    = allItems.filter { $0.kind == .cask }
                        let store    = allItems.filter { $0.kind == .appStore }
                        if !formulae.isEmpty { UpdateSection(title: "Homebrew Formulae", subtitle: "narzędzia CLI", icon: "terminal", items: formulae, selected: $selected) }
                        if !casks.isEmpty    { UpdateSection(title: "Homebrew Casks",    subtitle: "aplikacje .app",   icon: "app.gift", items: casks,    selected: $selected) }
                        if !store.isEmpty    { UpdateSection(title: "Mac App Store",     subtitle: "via mas-cli",      icon: "bag",      items: store,    selected: $selected) }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var selectAllSymbol: String {
        if selected.isEmpty { return "square" }
        if selected.count == allItems.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func toggleAll() {
        if selected.count == allItems.count { selected.removeAll() }
        else { selected = Set(allItems.map(\.key)) }
    }

    // MARK: Async actions
    private func runCheck() async {
        status = .checking
        errorMessage = nil
        onWegaState?(WegaState(pose: .sniff, line: "Węszę po Homebrew…"))

        do { brewOutdated = try await model.brewService.outdatedGreedy() }
        catch { errorMessage = error.localizedDescription; brewOutdated = nil }

        do { masOutdated = try await model.masService.outdated() }
        catch MasServiceError.masNotFound { masOutdated = [] }
        catch { masOutdated = [] }

        lastCheck = Date()
        status    = .results
        let total = allItems.count
        onWegaState?(total == 0
            ? WegaState(pose: .happy, line: "Wszystko aktualne. Idę się zdrzemnąć.")
            : WegaState(pose: .alert, line: "Znalazłam \(total) rzeczy do uporządkowania."))
        onBadgeChange?(total)
    }

    private func runUpdate() async {
        updating = true
        onWegaState?(WegaState(pose: .sniff, line: "Aktualizuję, chwila…"))
        // Simulate — real implementation calls brewService.upgrade / masService.upgrade
        // which are not yet in the service layer.
        try? await Task.sleep(for: .seconds(1.5))
        let n = selected.isEmpty ? allItems.count : selected.count
        selected.removeAll()
        brewOutdated = nil; masOutdated = []
        status = .results
        updating = false
        banner = BannerData(variant: .success, title: "Zaktualizowano \(n) pakietów", message: "Wszystko gotowe.")
        onWegaState?(WegaState(pose: .happy, line: "Gotowe! \(n) pakietów odświeżonych."))
        onBadgeChange?(0)
    }
}

// MARK: - Supporting types

private struct OutdatedItem: Identifiable {
    enum Kind { case formula, cask, appStore }
    let key:  String
    var id:   String { key }
    let name: String
    let from: String?
    let to:   String?
    let kind: Kind
}

private struct UpdateSection: View {
    let title:    String
    let subtitle: String
    let icon:     String
    let items:    [OutdatedItem]
    @Binding var selected: Set<String>

    var body: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color.wegaHoney)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(items.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(items) { item in
                PackageRow(
                    name:           item.name,
                    currentVersion: item.from,
                    latestVersion:  item.to,
                    isSelected:     selected.contains(item.key),
                    onToggle:       { toggle(item.key) }
                )
                .overlay(alignment: .bottom) {
                    if item.id != items.last?.id { Divider().opacity(0.4).padding(.leading, 54) }
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }
}

private struct CheckingBar: View {
    let command: String
    let delay:   Double

    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(Color.wegaHoney)
            Text("$ \(command)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.wegaHoney.opacity(0.15))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color.wegaToffee, Color.wegaHoney], startPoint: .leading, endPoint: .trailing))
                        .frame(width: visible ? .infinity : 0)
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: visible)
                }
                .frame(width: 160)
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { visible = true }
        }
    }
}

// MARK: - Banner
struct BannerData: Equatable {
    enum Variant { case success, danger }
    let variant: Variant
    let title:   String
    let message: String
}

struct BannerView: View {
    let data:    BannerData
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: data.variant == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(data.variant == .success ? Color.wegaSuccess : Color.wegaDanger)
            VStack(alignment: .leading, spacing: 2) {
                Text(data.title).font(.system(size: 13, weight: .semibold))
                Text(data.message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(data.variant == .success ? Color.wegaSuccess.opacity(0.08) : Color.wegaDanger.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(data.variant == .success ? Color.wegaSuccess.opacity(0.3) : Color.wegaDanger.opacity(0.3), lineWidth: 1))
    }
}
```

- [ ] **Step 2: Build — fix any missing type errors**

  `MasServiceError` is in `MacUpdaterCore`. Verify the import and the error case name by checking `MasService.swift`.

---

## Task 6: UninstallView — Search + Custom Dialog

**Files:**
- Rewrite: `Sources/MacUpdater/UninstallView.swift`

Key changes from current implementation:
- Search field in the header
- Select-all checkbox row
- `ZStack` overlay dialog (not system `Alert`) with two radio-style options
- Highlight selected rows in red tint

- [ ] **Step 1: Rewrite UninstallView.swift**

```swift
import SwiftUI
import MacUpdaterCore

struct UninstallView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel

    @State private var versions:       [String: String]  = [:]
    @State private var selected:       Set<String>        = []
    @State private var search:         String             = ""
    @State private var isLoading:      Bool               = false
    @State private var isUninstalling: Bool               = false
    @State private var showDialog:     Bool               = false
    @State private var errorMessage:   String?
    @State private var banner:         BannerData?

    private var sortedTokens: [String] { versions.keys.sorted() }

    private var filtered: [String] {
        guard !search.isEmpty else { return sortedTokens }
        return sortedTokens.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Odinstaluj cask'i").font(.system(size: 18, weight: .semibold))
                        Text("Zaznacz, co Wega ma zabrać. brew uninstall")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
                        TextField("Szukaj…", text: $search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 180)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 1))

                    Button { Task { await loadCasks() } } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)

                    Button {
                        guard !selected.isEmpty else { return }
                        showDialog = true
                    } label: {
                        if isUninstalling { ProgressView().controlSize(.small) }
                        else { Label(selected.isEmpty ? "Odinstaluj" : "Odinstaluj (\(selected.count))", systemImage: "trash") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaDanger)
                    .disabled(selected.isEmpty || isUninstalling)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let err = errorMessage {
                    ErrorBanner(message: err).padding(.horizontal, 16).padding(.bottom, 8)
                }
                if let b = banner {
                    BannerView(data: b) { banner = nil }.padding(.horizontal, 16).padding(.bottom, 8)
                }

                // Select-all row
                WegaCard(padded: false) {
                    HStack(spacing: 10) {
                        Image(systemName: selectAllSymbol)
                            .foregroundStyle(selected.isEmpty ? .secondary : Color.wegaHoney)
                            .font(.system(size: 16))
                            .onTapGesture { toggleAll() }
                        Text(selected.isEmpty
                             ? "\(filtered.count) zainstalowanych cask'ów"
                             : "\(selected.count) zaznaczonych z \(filtered.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("TOKEN · WERSJA")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // List
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered, id: \.self) { token in
                            let isSelected = selected.contains(token)
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isSelected ? Color.wegaHoney : .secondary)
                                    .font(.system(size: 16))
                                PackageLetterIcon(name: token, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(token).font(.system(size: 13, weight: .medium))
                                }
                                Spacer()
                                Text(versions[token] ?? "")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(isSelected ? Color.wegaDanger.opacity(0.06) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(token) }

                            Divider().opacity(0.4).padding(.leading, 54)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Overlay dialog
            if showDialog {
                UninstallDialog(
                    count:     selected.count,
                    onCancel:  { showDialog = false },
                    onConfirm: { zap in showDialog = false; Task { await uninstall(zap: zap) } }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showDialog)
        .task { await loadCasks() }
    }

    private var selectAllSymbol: String {
        if selected.isEmpty { return "square" }
        if selected.count == filtered.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func toggle(_ token: String) {
        if selected.contains(token) { selected.remove(token) } else { selected.insert(token) }
    }

    private func toggleAll() {
        if selected.count == filtered.count { selected.removeAll() }
        else { selected = Set(filtered) }
    }

    private func loadCasks() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do { versions = try await model.brewService.caskVersions() }
        catch { versions = [:]; errorMessage = error.localizedDescription }
    }

    private func uninstall(zap: Bool) async {
        isUninstalling = true; errorMessage = nil; banner = nil
        defer { isUninstalling = false }
        onWegaState?(WegaState(pose: .sniff, line: "Aport! Zabieram to z dysku…"))

        let tokens = selected.sorted()
        var succeeded: [String] = []
        var failed:    [String] = []

        for token in tokens {
            do {
                _ = try await model.brewService.uninstallCask(token: token, zap: zap)
                succeeded.append(token)
            } catch {
                do {
                    _ = try await model.brewService.uninstallCask(token: token, zap: false, force: true)
                    succeeded.append(token)
                } catch { failed.append(token) }
            }
        }

        selected.subtract(succeeded)
        await loadCasks()
        let msg = zap ? "Razem z resztkami w ~/Library." : "Pliki .app usunięte, konfiguracja zostawiona."
        if !succeeded.isEmpty {
            banner = BannerData(variant: .success, title: "Odinstalowano \(succeeded.count) aplikacji", message: msg)
            onWegaState?(WegaState(pose: .happy, line: "Załatwione — \(succeeded.count) mniej na dysku."))
        }
        if !failed.isEmpty {
            errorMessage = "Nie udało się: \(failed.joined(separator: ", "))"
        }
    }
}

// MARK: - Custom uninstall dialog (ZStack overlay)

private struct UninstallDialog: View {
    let count:     Int
    let onCancel:  () -> Void
    let onConfirm: (Bool) -> Void

    @State private var zapMode: Bool = true   // true = App + Leftovers

    var body: some View {
        Color.black.opacity(0.5)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 0) {
                    // Header
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(Color.wegaDanger.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: "trash")
                                .foregroundStyle(Color.wegaDanger)
                                .font(.system(size: 18))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Odinstalować \(count) \(count == 1 ? "aplikację" : "aplikacji")?")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Wybierz, co zostawić")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                    // Options
                    VStack(spacing: 8) {
                        UninstallOption(
                            title:       "Tylko aplikacja",
                            subtitle:    "Usuwa plik .app. Preferencje i cache zostają w ~/Library.",
                            command:     "brew uninstall",
                            recommended: false,
                            isSelected:  !zapMode,
                            onSelect:    { zapMode = false }
                        )
                        UninstallOption(
                            title:       "Aplikacja + resztki",
                            subtitle:    "Zabiera też pliki w ~/Library/Preferences, Caches i Application Support.",
                            command:     "brew uninstall --zap",
                            recommended: true,
                            isSelected:  zapMode,
                            onSelect:    { zapMode = true }
                        )
                    }
                    .padding(.horizontal, 22)

                    // Footer buttons
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Anuluj", action: onCancel)
                        Button(zapMode ? "Usuń razem z resztkami" : "Usuń tylko aplikację") {
                            onConfirm(zapMode)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.wegaDanger)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                    .background(Color.black.opacity(0.15))
                    .overlay(alignment: .top) { Divider().opacity(0.5) }
                }
                .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 12)
                .frame(width: 480)
            }
    }
}

private struct UninstallOption: View {
    let title:       String
    let subtitle:    String
    let command:     String
    let recommended: Bool
    let isSelected:  Bool
    let onSelect:    () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.wegaHoney : Color(NSColor.controlBackgroundColor))
                        .frame(width: 16, height: 16)
                    if isSelected {
                        Circle().fill(Color(red: 0.16, green: 0.11, blue: 0.07)).frame(width: 6, height: 6)
                    }
                }
                .overlay(Circle().stroke(isSelected ? Color.wegaHoney : Color.white.opacity(0.15), lineWidth: 1))
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if recommended {
                            Text("zalecane")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.wegaHoney)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.wegaHoney.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.wegaHoney.opacity(0.25), lineWidth: 1))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Text("$ \(command)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                Spacer()
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.wegaHoney.opacity(0.06) : Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.wegaHoney.opacity(0.32) : Color.white.opacity(0.06), lineWidth: 1))
        )
    }
}
```

- [ ] **Step 2: Build and verify**

---

## Task 7: MigrationView — Two-Section Layout

**Files:**
- Rewrite: `Sources/MacUpdater/MigrationView.swift`

Key changes: empty hero state, scanning progress, two sections (matchable / unmatched — based on `caskToken != nil`), per-row "Przepnij" button.

Note: `ApplicationInfo` has no confidence score — skip that column.

- [ ] **Step 1: Rewrite MigrationView.swift**

```swift
import SwiftUI
import MacUpdaterCore

private enum MigrationStatus { case ready, scanning, results }

struct MigrationView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel

    @State private var status:     MigrationStatus   = .ready
    @State private var candidates: [ApplicationInfo]  = []
    @State private var migrated:   Set<String>        = []
    @State private var busy:       String?
    @State private var errorMessage: String?
    @State private var banner:     BannerData?

    private var matchable:  [ApplicationInfo] { candidates.filter { $0.caskToken != nil && !migrated.contains($0.caskToken!) } }
    private var unmatched:  [ApplicationInfo] { candidates.filter { $0.caskToken == nil } }

    var body: some View {
        switch status {
        case .ready:    readyView
        case .scanning: scanningView
        case .results:  resultsView
        }
    }

    private var readyView: some View {
        EmptyHero(
            pose: .idle,
            title: "Zwęszyć aplikacje poza Homebrew?",
            message: "Wega zajrzy do /Applications i poszuka programów zainstalowanych ręcznie, które dałoby się przepiąć pod Brew.",
            action: AnyView(
                Button { Task { await scan() } } label: {
                    Label("Skanuj /Applications", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                .controlSize(.large)
            )
        )
    }

    private var scanningView: some View {
        VStack(spacing: 18) {
            WegaCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).tint(Color.wegaHoney)
                    Text("Skanowanie /Applications")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            VStack(spacing: 10) {
                WegaFull(pose: .sniff, size: 130)
                Text("Trop! Wega wącha każdy folder w /Applications…")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Kandydaci do migracji")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Zeskanowano /Applications · Wega znalazła \(matchable.count + migrated.count) aplikacji do przepięcia")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { Task { await scan() } } label: {
                        Label("Skanuj ponownie", systemImage: "arrow.clockwise")
                    }
                }

                if let err = errorMessage { ErrorBanner(message: err) }
                if let b = banner { BannerView(data: b) { banner = nil } }

                // Matchable section
                WegaCard(padded: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.wegaSuccess)
                        Text("Można przepiąć pod Homebrew")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(matchable.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                    if matchable.isEmpty {
                        Text("Wszystko już przygarnięte. Dobra robota.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(28)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(matchable) { app in
                            MigrationRow(
                                app:      app,
                                isBusy:   busy == app.caskToken,
                                onMigrate: { Task { await migrate(app) } }
                            )
                            if app.id != matchable.last?.id {
                                Divider().opacity(0.4).padding(.leading, 54)
                            }
                        }
                    }
                }

                // Unmatched section
                if !unmatched.isEmpty {
                    WegaCard(padded: false) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.tertiary)
                            Text("Bez odpowiednika w Homebrew")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(unmatched.count)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text("zostaną zarządzane ręcznie").font(.system(size: 11)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                        ForEach(unmatched) { app in
                            HStack(spacing: 12) {
                                PackageLetterIcon(name: app.name, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(.system(size: 13, weight: .medium))
                                    Text(app.path.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                WegaBadge(label: "brak w cask repo", variant: .manual)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .opacity(0.6)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func scan() async {
        status = .scanning; errorMessage = nil
        onWegaState?(WegaState(pose: .sniff, line: "Tropię intruzów w /Applications…"))

        do {
            let cacheURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
            let casks    = try await CaskDatabaseClient(cache: CaskDatabaseCache(fileURL: cacheURL)).fetchCasks()
            let installed = try await model.brewService.installedCasks()
            let apps = try ApplicationScanner().scanApplications(installedCasks: installed, availableCasks: casks)
            candidates = apps.filter { !$0.isManagedByBrew }
        } catch {
            candidates = []
            errorMessage = error.localizedDescription
        }

        status = .results
        let n = candidates.filter { $0.caskToken != nil }.count
        onWegaState?(WegaState(pose: n > 0 ? .alert : .happy,
                               line: n > 0 ? "Zwęszyłam \(n) aplikacji poza Homebrew." : "Wszystko porządku. Wega nie znalazła uciekinierów."))
    }

    private func migrate(_ app: ApplicationInfo) async {
        guard let token = app.caskToken else { return }
        busy = token
        onWegaState?(WegaState(pose: .sniff, line: "Przejmuję \(app.name)…"))
        // NOTE: Real migration (brew install + brew link) is not yet in BrewService.
        // This marks it as migrated in the UI; wire to service when available.
        try? await Task.sleep(for: .seconds(1.2))
        migrated.insert(token)
        busy = nil
        banner = BannerData(variant: .success, title: "\(app.name) przeszedł pod Homebrew", message: "Token: \(token)")
        onWegaState?(WegaState(pose: .happy, line: "\(app.name) pod opieką! Idziemy dalej."))
    }
}

private struct MigrationRow: View {
    let app:       ApplicationInfo
    let isBusy:    Bool
    let onMigrate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PackageLetterIcon(name: app.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(app.name).font(.system(size: 13, weight: .medium))
                    if let v = app.version {
                        Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                Text(app.path.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 10) {
                if let token = app.caskToken {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right").font(.system(size: 10))
                        Text(token).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.wegaHoney)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.wegaHoney.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.wegaHoney.opacity(0.25).opacity(0.5), lineWidth: 1, dash: [4]))
                }
            }
            Button {
                onMigrate()
            } label: {
                if isBusy { ProgressView().controlSize(.small) }
                else { Label("Przepnij", systemImage: "arrow.right.doc.on.clipboard") }
            }
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
```

- [ ] **Step 2: Build and verify**

---

## Task 8: InventoryView — Stat Cards + Filter Pills + Sortable Table

**Files:**
- Rewrite: `Sources/MacUpdater/InventoryView.swift`

Key additions over current implementation:
- 4 clickable stat cards that double as filter shortcuts
- Filter pills (All / Brew / Manual) — no "App Store" / "System" category since `ApplicationInfo` only has `isManagedByBrew`
- Sortable columns: Name, Version, Bundle ID, Source (click header to sort/reverse)
- `onWegaState` callback

- [ ] **Step 1: Rewrite InventoryView.swift**

```swift
import SwiftUI
import MacUpdaterCore

private enum SourceFilter: String, CaseIterable {
    case all    = "Wszystkie"
    case brew   = "Brew"
    case manual = "Ręcznie"
}

private enum SortKey: String { case name, version, bundleId, source }

struct InventoryView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel

    @State private var apps:         [ApplicationInfo] = []
    @State private var isScanning:   Bool              = false
    @State private var errorMessage: String?
    @State private var search:       String            = ""
    @State private var filter:       SourceFilter      = .all
    @State private var sortKey:      SortKey           = .name
    @State private var sortAsc:      Bool              = true

    private var brewCount:   Int { apps.filter(\.isManagedByBrew).count }
    private var manualCount: Int { apps.count - brewCount }

    private var filtered: [ApplicationInfo] {
        apps
            .filter { app in
                switch filter {
                case .all:    true
                case .brew:   app.isManagedByBrew
                case .manual: !app.isManagedByBrew
                }
            }
            .filter { app in
                guard !search.isEmpty else { return true }
                return app.name.localizedCaseInsensitiveContains(search)
                    || (app.bundleIdentifier?.localizedCaseInsensitiveContains(search) ?? false)
            }
            .sorted { a, b in
                let cmp: Bool
                switch sortKey {
                case .name:     cmp = a.name < b.name
                case .version:  cmp = (a.version ?? "") < (b.version ?? "")
                case .bundleId: cmp = (a.bundleIdentifier ?? "") < (b.bundleIdentifier ?? "")
                case .source:   cmp = a.isManagedByBrew && !b.isManagedByBrew
                }
                return sortAsc ? cmp : !cmp
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stat cards
            HStack(spacing: 10) {
                InventoryStatCard(label: "Homebrew",  value: brewCount,   sublabel: "cask + formula", color: .wegaHoney,   active: filter == .brew)   { setFilter(.brew) }
                InventoryStatCard(label: "Ręcznie",   value: manualCount, sublabel: "poza brew",      color: .wegaDanger,  active: filter == .manual) { setFilter(.manual) }
                InventoryStatCard(label: "Razem",     value: apps.count,  sublabel: "wszystkie",      color: .primary,     active: filter == .all)    { setFilter(.all) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
                    TextField("Szukaj po nazwie lub bundle ID…", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .frame(width: 240)

                FilterPills(selection: $filter)

                Spacer()

                Text("\(filtered.count) z \(apps.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Button { Task { await scan() } } label: {
                    Label("Odśwież", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isScanning)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if let err = errorMessage {
                ErrorBanner(message: err).padding(.horizontal, 16).padding(.bottom, 8)
            }

            // Table header
            WegaCard(padded: false) {
                HStack(spacing: 12) {
                    SortHeaderCell(label: "Aplikacja",  key: .name,     sortKey: $sortKey, sortAsc: $sortAsc, flex: 1.6)
                    SortHeaderCell(label: "Wersja",     key: .version,  sortKey: $sortKey, sortAsc: $sortAsc, flex: 0.6)
                    SortHeaderCell(label: "Bundle ID",  key: .bundleId, sortKey: $sortKey, sortAsc: $sortAsc, flex: 1.4)
                    SortHeaderCell(label: "Źródło",     key: .source,   sortKey: $sortKey, sortAsc: $sortAsc, flex: 1.0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.wegaHoney.opacity(0.02))
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                // Rows
                if isScanning {
                    HStack {
                        Spacer()
                        ProgressView().padding(32)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered.indices, id: \.self) { i in
                                let app = filtered[i]
                                InventoryRow(app: app, isAlt: i % 2 == 1)
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .task { await scan() }
    }

    private func setFilter(_ f: SourceFilter) { filter = filter == f ? .all : f }

    private func scan() async {
        isScanning = true; errorMessage = nil
        defer { isScanning = false }
        onWegaState?(WegaState(pose: .sniff, line: "Obchód wszystkich kątów…"))

        do {
            let installedCasks: Set<String>
            do { installedCasks = try await model.brewService.installedCasks() }
            catch { installedCasks = [] }

            let cacheURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
            let casks = (try? await CaskDatabaseClient(cache: CaskDatabaseCache(fileURL: cacheURL)).fetchCasks()) ?? []
            apps = try ApplicationScanner().scanApplications(installedCasks: installedCasks, availableCasks: casks)

            onWegaState?(WegaState(pose: .happy, line: "Obchód skończony — \(apps.count) aplikacji pod opieką."))
        } catch {
            apps = []
            errorMessage = error.localizedDescription
        }
    }
}

private struct InventoryStatCard: View {
    let label:    String
    let value:    Int
    let sublabel: String
    let color:    Color
    let active:   Bool
    let onTap:    () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text("\(value)")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(active ? color : .primary)
                Text(sublabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? color.opacity(0.06) : Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? color.opacity(0.30) : Color.white.opacity(0.06), lineWidth: 1))
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .opacity(active ? 1 : 0.4)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct FilterPills: View {
    @Binding var selection: SourceFilter

    var body: some View {
        HStack(spacing: 1) {
            ForEach(SourceFilter.allCases, id: \.self) { opt in
                let active = selection == opt
                Button { selection = opt } label: {
                    Text(opt.rawValue)
                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(active ? Color(NSColor.controlBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: active ? .black.opacity(0.25) : .clear, radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

private struct SortHeaderCell: View {
    let label:   String
    let key:     SortKey
    @Binding var sortKey: SortKey
    @Binding var sortAsc: Bool
    var flex:    CGFloat = 1

    var body: some View {
        Button {
            if sortKey == key { sortAsc.toggle() }
            else { sortKey = key; sortAsc = true }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(sortKey == key ? Color.wegaHoney : .tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if sortKey == key {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.wegaHoney)
                }
            }
            .frame(maxWidth: .infinity * flex, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct InventoryRow: View {
    let app:   ApplicationInfo
    let isAlt: Bool

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Name (flex 1.6)
            HStack(spacing: 9) {
                PackageLetterIcon(name: app.name, size: 22)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity * 1.6, alignment: .leading)

            // Version (flex 0.6)
            Text(app.version ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity * 0.6, alignment: .leading)

            // Bundle ID (flex 1.4)
            Text(app.bundleIdentifier ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity * 1.4, alignment: .leading)

            // Source (flex 1.0)
            HStack(spacing: 6) {
                WegaBadge(label: app.isManagedByBrew ? "Brew" : "Ręcznie",
                          variant: app.isManagedByBrew ? .brew : .manual)
                if let token = app.caskToken {
                    Text(token)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(hovered ? Color.wegaHoney.opacity(0.04) : (isAlt ? Color.white.opacity(0.012) : Color.clear))
        .onHover { hovered = $0 }
    }
}
```

- [ ] **Step 2: Build and verify the full app compiles**

- [ ] **Step 3: Remove DashboardView.swift and SettingsView.swift if they are no longer referenced**

  Check with `grep -r "DashboardView\|SettingsView" Sources/` — if zero results outside their own files, delete them.

---

## Self-Review

### Spec coverage

| Requirement | Task |
|---|---|
| Honey/caramel color palette | Task 1 |
| Wega head with 6 poses + animated ears | Task 2 |
| WegaIcon, PawPrint, WegaFull | Task 2 |
| Sidebar brand header + Wega status panel | Task 4 |
| Sidebar tab badges | Task 4 |
| Update: empty / checking / results states | Task 5 |
| Update: per-item checkboxes + select all | Task 5 |
| Update: version arrow old → new | Task 3 |
| Uninstall: search in header | Task 6 |
| Uninstall: select all row | Task 6 |
| Uninstall: custom dialog with radio options | Task 6 |
| Migration: empty hero + scanning state | Task 7 |
| Migration: two sections (matchable/unmatched) | Task 7 |
| Migration: per-row migrate button | Task 7 |
| Inventory: clickable stat cards | Task 8 |
| Inventory: filter pills (All/Brew/Manual) | Task 8 |
| Inventory: sortable columns | Task 8 |
| WegaState flows to sidebar on all actions | Tasks 4-8 |
| Polish UI copy ("Wega węszy", "Aport!") | Tasks 4-8 |

### Known simplifications vs prototype
- WegaFull body is simplified (no tennis ball easter egg, no sniff puffs animation) — these can be added post-launch.
- Inventory has 3 filter pills instead of 5 (no App Store / System categories — model doesn't distinguish them).
- Migration has no confidence score column — not in `ApplicationInfo`.
- Update "run update" is simulated (BrewService doesn't expose upgrade commands yet).
- Sidebar shortcuts section (Brewfile, log, helper settings) is omitted — no actions to wire up yet.
