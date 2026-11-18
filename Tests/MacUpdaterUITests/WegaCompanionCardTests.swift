import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// UX-15 — Wega had no place of her own outside the empty states: a speech bubble popped over
/// the list for 4.5 s, a footer under every tab repeated the sidebar's counts, the
/// notification question was a strip above the content, and `WegaState.line` was computed
/// for every tab and never shown. A card at the bottom of the sidebar now carries all of it.
@Suite("Wega companion card")
@MainActor
struct WegaCompanionCardTests {
    @Test func aFreshQuipOutranksTheTabLine() {
        let state = WegaState.forTab(.update)

        #expect(WegaCompanionPresentation(state: state, quip: nil, lastCheck: nil).line == state.line)
        #expect(WegaCompanionPresentation(state: state, quip: "Hau!", lastCheck: nil).line == "Hau!")
    }

    @Test func theCardSaysWhenWegaLastLooked() {
        let state = WegaState.forTab(.update)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(WegaCompanionPresentation(state: state, quip: nil, lastCheck: nil).freshness
                == tr("Jeszcze nie sprawdzano"))
        #expect(WegaCompanionPresentation(state: state, quip: nil, lastCheck: date).freshness
                == trf("Sprawdzono %@", date.formatted(date: .omitted, time: .shortened)))
    }

    /// The quip comments on the result, and a pending security fix wins over the count.
    @Test func theQuipFollowsWhatTheScanFound() {
        #expect(WegaCompanionPresentation.finishedQuip(updateCount: 3, securityCount: 1)
                == tr("Znalazłam coś pilnego."))
        #expect(WegaCompanionPresentation.finishedQuip(updateCount: 0, securityCount: 0)
                == tr("Wszystko pod kontrolą!"))
        #expect(WegaCompanionPresentation.finishedQuip(updateCount: 4, securityCount: 0)
                == tr("Hau! Nowe paczki?"))
    }

    /// The card sits in the sidebar's safe area, and a sidebar whose geometry moved during a
    /// scan once sent AppKit into a constraint loop. Whatever the card says — a short line,
    /// a long one, or the notification question with its buttons — its height is the same.
    @Test func theCardKeepsOneHeightWhateverItSays() {
        let state = WegaState.forTab(.update)
        func height(_ view: WegaCompanionCardContent) -> CGFloat {
            NSHostingView(rootView: view.frame(width: 220)).fittingSize.height
        }
        let quiet = WegaCompanionCardContent(
            presentation: WegaCompanionPresentation(state: state, quip: nil, lastCheck: nil)
        )
        let talkative = WegaCompanionCardContent(
            presentation: WegaCompanionPresentation(
                state: state,
                quip: String(repeating: "Bardzo długa wypowiedź Wegi ", count: 8),
                lastCheck: Date()
            )
        )
        let asking = WegaCompanionCardContent(
            presentation: WegaCompanionPresentation(state: state, quip: nil, lastCheck: nil),
            asksForNotifications: true
        )

        #expect(height(quiet) > 0)
        #expect(height(talkative) == height(quiet))
        #expect(height(asking) == height(quiet))
    }

    @Test func theFooterTheBubbleAndTheStripAreGone() throws {
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        let sidebar = try source("Sources/MacUpdater/SidebarList.swift")

        #expect(!detail.contains("StatusFooter("), "the counts are already the sidebar's badges")
        #expect(!detail.contains("WegaSpeechBubble("), "the quip lives in the card")
        #expect(!detail.contains("NotificationExplanationCard()"), "Wega asks from the card")
        #expect(sidebar.contains("WegaCompanionCard("))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
