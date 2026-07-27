import AppKit
import Foundation
import SwiftUI

struct BinaryStreamLane: Identifiable, Equatable {
    let id: Int
    let glyphs: String
    let speed: Double
    let yFraction: CGFloat
    let opacity: Double
    let fontSize: CGFloat
    let phase: Double
}

enum BinaryStreamLaneFactory {
    private static let stableSeed: UInt64 = 0x5745_4741_4D41_4321

    static func make(lanes: Int, baseSpeed: Double) -> [BinaryStreamLane] {
        let laneCount = max(0, lanes)
        guard laneCount > 0 else { return [] }

        var rng = BinaryStreamRandomNumberGenerator(seed: stableSeed)
        return (0..<laneCount).map { index in
            var glyphs = ""
            for _ in 0..<160 {
                glyphs.append(Bool.random(using: &rng) ? "1" : "0")
                if Int.random(in: 0...5, using: &rng) == 0 { glyphs.append(" ") }
            }

            let speedJitter = Double.random(in: 0.55...1.45, using: &rng)
            let direction: Double = Bool.random(using: &rng) ? 1 : -1
            return BinaryStreamLane(
                id: index,
                glyphs: glyphs,
                speed: baseSpeed * speedJitter * direction,
                yFraction: (CGFloat(index) + 0.5) / CGFloat(laneCount),
                opacity: Double.random(in: 0.10...0.32, using: &rng),
                fontSize: CGFloat.random(in: 10...15, using: &rng),
                phase: Double.random(in: 0...1, using: &rng)
            )
        }
    }
}

private struct BinaryStreamRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Precomputes each lane's glyph size once and produces per-frame draw placements
/// without re-measuring text. A lane's glyph size depends only on its glyphs and
/// font size — never on the animation frame — so measurement is hoisted into `init`
/// instead of running inside the 30-fps Canvas loop (ARCH-08d). Only the cheap
/// offset arithmetic that actually changes per frame stays in `placements(at:)`.
struct BinaryStreamFrameRenderer {
    struct Placement: Equatable {
        let lane: BinaryStreamLane
        let primary: CGPoint
        let secondary: CGPoint?
    }

    private let lanes: [BinaryStreamLane]
    private let glyphSizes: [CGSize]

    init(lanes: [BinaryStreamLane], measure: (BinaryStreamLane) -> CGSize) {
        self.lanes = lanes
        self.glyphSizes = lanes.map(measure)
    }

    func placements(at time: TimeInterval, canvasSize: CGSize) -> [Placement] {
        var placements: [Placement] = []
        placements.reserveCapacity(lanes.count)
        for (lane, glyphSize) in zip(lanes, glyphSizes) {
            guard glyphSize.width > 0 else { continue }

            let travel = glyphSize.width
            let offset = (time * lane.speed + lane.phase * travel)
                .truncatingRemainder(dividingBy: travel)
            let normalized = offset >= 0 ? offset : offset + travel

            let y = lane.yFraction * canvasSize.height - glyphSize.height / 2
            let x1 = -normalized
            let x2 = x1 + travel
            placements.append(
                Placement(
                    lane: lane,
                    primary: CGPoint(x: x1, y: y),
                    secondary: x2 < canvasSize.width ? CGPoint(x: x2, y: y) : nil
                )
            )
        }
        return placements
    }
}

/// The render schedule is a value so Reduce Motion is both enforceable and unit-testable.
/// A static mode never creates a `TimelineView`, avoiding hidden 30-fps work as well as motion.
enum BinaryStreamMotionMode: Equatable {
    case animated(minimumInterval: TimeInterval)
    case staticFrame(Date)

    static let referenceDate = Date(timeIntervalSinceReferenceDate: 0)

    init(reduceMotion: Bool) {
        self = reduceMotion
            ? .staticFrame(Self.referenceDate)
            : .animated(minimumInterval: 1.0 / 30.0)
    }

    func renderDate(at currentDate: Date) -> Date {
        switch self {
        case .animated:
            return currentDate
        case .staticFrame(let date):
            return date
        }
    }
}

/// Horizontal stream of 0/1 glyphs drifting across the view, used as a
/// backdrop while Wega "sniffs" the binary code during update scanning.
struct BinaryStream: View {
    var lanes: Int = 9
    var color: Color = .wegaHoney
    var baseSpeed: Double = 38

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let laneData: [BinaryStreamLane]
    private let frameRenderer: BinaryStreamFrameRenderer

    init(lanes: Int = 9, color: Color = .wegaHoney, baseSpeed: Double = 38) {
        self.lanes = lanes
        self.color = color
        self.baseSpeed = baseSpeed

        let laneData = BinaryStreamLaneFactory.make(lanes: lanes, baseSpeed: baseSpeed)
        self.laneData = laneData
        self.frameRenderer = BinaryStreamFrameRenderer(
            lanes: laneData,
            measure: BinaryStream.measureGlyphs
        )
    }

    /// Measures a lane's glyph run from font metrics alone. The size depends only on
    /// the glyphs and font size, so this runs once at construction (see
    /// `BinaryStreamFrameRenderer`) rather than on every animation frame.
    private static func measureGlyphs(_ lane: BinaryStreamLane) -> CGSize {
        let font = NSFont.monospacedSystemFont(ofSize: lane.fontSize, weight: .regular)
        return NSAttributedString(string: lane.glyphs, attributes: [.font: font]).size()
    }

    var body: some View {
        Group {
            switch BinaryStreamMotionMode(reduceMotion: reduceMotion) {
            case .animated(let minimumInterval):
                TimelineView(.animation(minimumInterval: minimumInterval)) { context in
                    stream(at: context.date)
                }
            case .staticFrame(let date):
                stream(at: date)
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear,        location: 0.00),
                    .init(color: .black,        location: 0.08),
                    .init(color: .black,        location: 0.92),
                    .init(color: .clear,        location: 1.00)
                ],
                startPoint: .leading,
                endPoint:   .trailing
            )
        )
        // The Canvas draws 160-glyph lanes that overflow its own bounds by design (they
        // scroll and are gradient-masked). Without pinning the layout width, that intrinsic
        // width propagates up and forces the detail column so wide it shoves the sidebar off
        // the window's left edge during a scan. `maxWidth: .infinity` with a zero floor keeps
        // the stream purely decorative: it fills whatever width it is given and demands none.
        .frame(minWidth: 0, maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stream(at date: Date) -> some View {
        Canvas { ctx, size in
            let t = date.timeIntervalSinceReferenceDate
            for placement in frameRenderer.placements(at: t, canvasSize: size) {
                let lane = placement.lane
                // UX-03-fixed-size: decorative glyph rain drawn into a `Canvas`, sized per
                // lane by the animation model to fake depth. It carries no information and
                // is measured once per lane, so it must not move with the text setting.
                let font = Font.system(size: lane.fontSize, weight: .regular, design: .monospaced)
                let text = Text(lane.glyphs).font(font).foregroundStyle(color)
                let resolved = ctx.resolve(text)

                ctx.opacity = lane.opacity
                ctx.draw(resolved, at: placement.primary, anchor: .topLeading)
                if let secondary = placement.secondary {
                    ctx.draw(resolved, at: secondary, anchor: .topLeading)
                }
            }
        }
    }
}
