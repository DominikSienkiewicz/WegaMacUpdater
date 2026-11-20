import Foundation
import Testing
@testable import WegaMacUpdater

/// UX-17 — a ball rolls past, Wega glances after it and runs off to fetch it, then comes
/// back with it. The choreography is one value both drawings play (the full Wega on calm
/// empty states and the portrait in the sidebar card), so its rules are pinned once here.
@Suite("Ball chase")
@MainActor
struct BallChaseTests {
    @Test(arguments: [CGFloat(1), CGFloat(-1)])
    func wegaLooksAndRunsWhereTheBallWent(direction: CGFloat) {
        let chase = BallChase(direction: direction, span: 100)

        #expect(chase.ballStart.sign != chase.ballEnd.sign, "the ball rolls past her, side to side")
        #expect((chase.glanceRotation > 0) == (chase.ballEnd > 0), "she glances after the ball")
        #expect(chase.runOut.sign == chase.ballEnd.sign, "she runs the way the ball went")
        #expect(chase.reentry.sign != chase.runOut.sign, "and comes back from the other side")
        #expect(abs(chase.runOut) >= 100, "running off means leaving the stage")
    }

    /// She notices the ball while it is still on its way past, not before it arrives or after
    /// it has gone.
    @Test func theGlanceComesWhileTheBallIsPassing() {
        #expect(BallChase.glanceDelay > .zero)
        #expect(BallChase.glanceDelay < BallChase.ballFlight)
    }

    @Test func theChaseIsATrickAndTheFirstOneShown() {
        #expect(PlayfulWega.Trick.allCases.contains(.chase))
        #expect(PlayfulWega.openingTrick == .chase)
    }

    /// The sidebar card plays it only when it is the live card, and never over the
    /// notification question, whose buttons must not move.
    @Test func theSidebarCardChasesOnlyWhenIdle() throws {
        let card = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MacUpdater/WegaCompanionCard.swift"),
            encoding: .utf8
        )

        // UXP-27 — the live card plays unless an error, a run or a dialog holds the user's attention.
        #expect(card.contains("playsWithBall: !attentionHeld"), "the live card plays")
        #expect(card.contains("var attentionHeld = false"), "and nothing holds it unless told so")
        #expect(card.contains("guard playsWithBall, !asksForNotifications"))
        #expect(card.contains("ContinuousMotion.loopsIdleAnimations(reduceMotion: reduceMotion)"),
                "Reduce Motion keeps her still, like every idle animation")
    }
}
