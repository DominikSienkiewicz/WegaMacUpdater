import Foundation
import SwiftUI

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

    private struct Lane: Identifiable {
        let id: Int
        let glyphs: String
        let speed: Double
        let yFraction: CGFloat
        let opacity: Double
        let fontSize: CGFloat
        let phase: Double
    }

    private let laneData: [Lane]

    init(lanes: Int = 9, color: Color = .wegaHoney, baseSpeed: Double = 38) {
        self.lanes = lanes
        self.color = color
        self.baseSpeed = baseSpeed

        var rng = SystemRandomNumberGenerator()
        var data: [Lane] = []
        for i in 0..<lanes {
            var s = ""
            for _ in 0..<160 {
                let bit = Bool.random(using: &rng) ? "1" : "0"
                s.append(bit)
                if Int.random(in: 0...5, using: &rng) == 0 { s.append(" ") }
            }
            let speedJitter = Double.random(in: 0.55...1.45, using: &rng)
            let opacity     = Double.random(in: 0.10...0.32, using: &rng)
            let fontSize    = CGFloat.random(in: 10...15, using: &rng)
            let phase       = Double.random(in: 0...1, using: &rng)
            let direction: Double = Bool.random(using: &rng) ? 1 : -1
            data.append(
                Lane(
                    id: i,
                    glyphs: s,
                    speed: baseSpeed * speedJitter * direction,
                    yFraction: (CGFloat(i) + 0.5) / CGFloat(lanes),
                    opacity: opacity,
                    fontSize: fontSize,
                    phase: phase
                )
            )
        }
        self.laneData = data
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
            for lane in laneData {
                let font = Font.system(size: lane.fontSize, weight: .regular, design: .monospaced)
                let text = Text(lane.glyphs).font(font).foregroundStyle(color)
                let resolved = ctx.resolve(text)
                let glyphSize = resolved.measure(
                    in: CGSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                )
                guard glyphSize.width > 0 else { continue }

                let travel = glyphSize.width
                let offset = (t * lane.speed + lane.phase * travel)
                    .truncatingRemainder(dividingBy: travel)
                let normalized = offset >= 0 ? offset : offset + travel

                let y = lane.yFraction * size.height - glyphSize.height / 2
                let x1 = -normalized
                let x2 = x1 + travel

                ctx.opacity = lane.opacity
                ctx.draw(resolved, at: CGPoint(x: x1, y: y), anchor: .topLeading)
                if x2 < size.width {
                    ctx.draw(resolved, at: CGPoint(x: x2, y: y), anchor: .topLeading)
                }
            }
        }
    }
}
