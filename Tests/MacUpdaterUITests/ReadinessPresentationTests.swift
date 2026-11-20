import AppKit
import SwiftUI
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Readiness card") @MainActor
struct ReadinessPresentationTests {
    @Test func showsOnlyBeforeTheFirstRunAndOnlyWithUpdates() {
        let base = { (d: Bool, u: Bool) in ReadinessPresentation(dismissed: d, hasUpdates: u, appManagement: .unknown,
                     touchID: .available, helper: .notRegistered, notificationsUnanswered: true) }
        #expect(base(false, true).isVisible)
        #expect(!base(true, true).isVisible)
        #expect(!base(false, false).isVisible)
    }

    @Test func passwordIsReadyWithTouchIDOrTheHelper() {
        let touch = ReadinessPresentation(dismissed: false, hasUpdates: true, appManagement: .granted,
                     touchID: .enabled, helper: .notRegistered, notificationsUnanswered: false)
        let helper = ReadinessPresentation(dismissed: false, hasUpdates: true, appManagement: .granted,
                     touchID: .available, helper: .enabled, notificationsUnanswered: false)
        #expect(touch.rows.contains(.password(ready: true)) && helper.rows.contains(.password(ready: true)))
        #expect(!touch.rows.contains(.notifications))
    }

    @Test func theCardAsksNothingItDoesNotNeed() {
        let p = ReadinessPresentation(dismissed: false, hasUpdates: true, appManagement: .denied,
                 touchID: .notSupported, helper: .notRegistered, notificationsUnanswered: true)
        #expect(p.rows == [.checking, .replaceApps(.denied), .password(ready: false), .notifications])
    }

    /// I2 — the card's height is fixed, and the frame clips. With every row present the
    /// buttons that close the card („Później”, „Wszystko jasne”) were cut off, so the fixed
    /// height has to hold the worst row set: App Management denied, Touch ID available,
    /// notifications unanswered — at the narrowest detail column and the widest, in both languages.
    @Test(arguments: [AppLanguage.pl, .en], [CGFloat(420), 680])
    func theWorstRowSetFitsTheFixedHeight(language: AppLanguage, detailWidth: CGFloat) {
        let worst: [ReadinessPresentation.Row] = [.checking, .replaceApps(.denied), .password(ready: false), .notifications]
        let natural = withLanguage(language) {
            NSHostingView(rootView: ReadinessCardContent(rows: worst, touchID: .available, probing: false)
                .padding(.horizontal, WegaLayout.listGutter)
                .frame(width: detailWidth)).fittingSize.height
        }
        #expect(natural <= ReadinessCard.baseHeight,
                "I2: \(language) at \(detailWidth) pt needs \(natural) pt, the card is \(ReadinessCard.baseHeight) pt")
    }
}
