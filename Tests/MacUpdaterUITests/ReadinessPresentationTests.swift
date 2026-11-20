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
}
