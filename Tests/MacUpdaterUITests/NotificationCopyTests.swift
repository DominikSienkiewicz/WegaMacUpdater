import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Notification copy") @MainActor
struct NotificationCopyTests {
    @Test(arguments: [1, 2, 3, 5, 22])
    func newUpdatesNameTheAppsAndCountTheRest(total: Int) {
        let names = (1...total).map { "App\($0)" }
        let body = NotificationCopy.newUpdatesBody(names: names)
        #expect(body.hasPrefix(tr("Nowe aktualizacje:")))
        if total <= 2 {
            #expect(body.contains(names.joined(separator: ", ")))
        } else {
            #expect(body.contains(trp("i %@ innych", total - 2)))
        }
    }

    @Test func polishFormsAreRight() {
        LocalizedStrings.withScopedLanguage(.pl) {
            #expect(trp("i %@ innych", 1) == "i 1 inna")
            #expect(trp("i %@ innych", 3) == "i 3 inne")
            #expect(trp("i %@ innych", 12) == "i 12 innych")
            #expect(NotificationCopy.backgroundUpdatedClause(count: 22) == "W tle zaktualizowałam 22 aplikacje.")
            #expect(NotificationCopy.newUpdatesBody(names: ["Slack", "Zoom", "Figma"]) == "Nowe aktualizacje: Slack, Zoom i 1 inna.")
        }
    }

    @Test func englishFormsAreRight() {
        LocalizedStrings.withScopedLanguage(.en) {
            #expect(NotificationCopy.backgroundUpdatedClause(count: 1) == "I updated 1 app in the background.")
            #expect(NotificationCopy.backgroundUpdatedClause(count: 5) == "I updated 5 apps in the background.")
            #expect(NotificationCopy.newUpdatesBody(names: ["Slack", "Zoom", "Figma"]) == "New updates: Slack, Zoom and 1 more.")
        }
    }
}
