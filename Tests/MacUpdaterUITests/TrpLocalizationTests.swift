import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// UX-08 — `trp(base, count)` renders the menu-bar update counter with the plural form
/// that matches both the count and the active language. Serialized because it toggles
/// the process-wide `LocalizedStrings.current`; the previous language is restored after
/// each case so the switch never leaks into other suites.
@Suite("TrpLocalization", .serialized)
struct TrpLocalizationTests {

    private let updatesAvailable = "%@ aktualizacji dostępnych"

    private func withLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let previous = LocalizedStrings.current
        LocalizedStrings.current = language
        defer { LocalizedStrings.current = previous }
        body()
    }

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
