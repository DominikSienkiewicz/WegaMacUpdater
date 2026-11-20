import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// UX-08 — `trp(base, count)` renders the menu-bar update counter with the plural form
/// that matches both the count and the active language.
@Suite("TrpLocalization")
struct TrpLocalizationTests {

    private let updatesAvailable = "%@ aktualizacji dostępnych"

    @Test func polishMenuBarCounterMatchesTheCount() {
        withLanguage(.pl) {
            #expect(trp(updatesAvailable, 1) == "1 aktualizacja dostępna")
            #expect(trp(updatesAvailable, 3) == "3 aktualizacje dostępne")
            #expect(trp(updatesAvailable, 13) == "13 aktualizacji dostępnych")
            #expect(trp(updatesAvailable, 5) == "5 aktualizacji dostępnych")
        }
    }

    @Test func englishMenuBarCounterMatchesTheCount() {
        withLanguage(.en) {
            #expect(trp(updatesAvailable, 1) == "1 update available")
            #expect(trp(updatesAvailable, 3) == "3 updates available")
            #expect(trp(updatesAvailable, 13) == "13 updates available")
        }
    }
}
