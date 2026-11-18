import SwiftUI

// MARK: - Choreography (UX-17)

/// A ball rolls past, Wega glances after it, runs off the way it went and comes back with it
/// from the other side.
///
/// Written once, in the drawing's own units, so the full Wega on calm empty states
/// (`PlayfulWega`) and the portrait in the sidebar card (`WegaCompanionCardContent`) tell the
/// same story. Both play it from an idle loop that "Ogranicz ruch" switches off, and both move
/// only by offset and rotation, so neither changes the layout around it.
struct BallChase: Equatable {
    /// +1: the ball rolls left to right; −1: right to left.
    let direction: CGFloat
    /// How far from Wega's resting place "off stage" is.
    let span: CGFloat

    static func random(span: CGFloat) -> BallChase {
        BallChase(direction: Bool.random() ? 1 : -1, span: span)
    }

    var ballStart: CGFloat { -direction * span }
    var ballEnd: CGFloat { direction * span }
    /// The glance: a turn of the head after the ball.
    var glanceRotation: Double { 10 * Double(direction) }
    /// A little further than the ball, so she is clear of the stage before turning back.
    var runOut: CGFloat { direction * span * 1.15 }
    var reentry: CGFloat { -direction * span * 1.15 }
    /// The ball rolls, so it turns the way it travels.
    var ballSpin: Double { 540 * Double(direction) }

    /// Seconds. The ball's whole trip past her.
    static let ballFlight: Double = 0.9
    /// About when the ball passes her: she notices it on its way, not before it arrives.
    static let glanceDelay: Double = 0.38
    static let glanceHold: Double = 0.55
    static let run: Double = 0.6
    static let comeBack: Double = 0.75
    static let proud: Double = 0.9
}

// MARK: - Ball

/// Wega's red ball, drawn once: the full mascot's resting ball and the one she chases.
struct WegaBall: View {
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 1.0, green: 0.38, blue: 0.22),
                        Color(red: 0.62, green: 0.06, blue: 0.0),
                    ],
                    center: .init(x: 0.35, y: 0.28),
                    startRadius: 0,
                    endRadius: diameter * 0.54
                )
            )
            .overlay(
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .scaleEffect(0.35)
                    .offset(x: -diameter * 0.15, y: -diameter * 0.15)
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}
