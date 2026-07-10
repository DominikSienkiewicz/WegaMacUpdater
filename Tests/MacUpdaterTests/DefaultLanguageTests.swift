import XCTest
@testable import MacUpdaterCore

/// M1 — the UI language chosen on first launch, when `wega.language` is unset.
/// Polish is opt-in by locale; everyone else gets English.
final class DefaultLanguageTests: XCTestCase {
    func testEnglishLocalePicksEnglish() {
        XCTAssertEqual(defaultLanguage(preferredLanguages: ["en-US"]), .en)
    }

    func testPolishLocalePicksPolish() {
        XCTAssertEqual(defaultLanguage(preferredLanguages: ["pl-PL"]), .pl)
    }

    func testEmptyPreferencesPickEnglish() {
        XCTAssertEqual(defaultLanguage(preferredLanguages: []), .en)
    }

    func testUnshippedLocalePicksEnglish() {
        XCTAssertEqual(defaultLanguage(preferredLanguages: ["de-DE"]), .en)
    }

    /// A Pole on a German system: skip the language Wega does not ship, honour the next one.
    func testUnshippedLocaleFallsThroughToTheNextPreference() {
        XCTAssertEqual(defaultLanguage(preferredLanguages: ["de-DE", "pl-PL"]), .pl)
    }

    func testBareSubtagWithoutRegionIsAccepted() {
        XCTAssertEqual(defaultLanguage(preferredLanguages: ["pl"]), .pl)
    }
}

/// The presentation side of `AppLanguage`. Small, but it is the only thing the Settings
/// picker renders, and it was the one part of the M1 type nothing exercised.
final class AppLanguagePresentationTests: XCTestCase {
    func testEveryShippedLanguageHasAName() {
        XCTAssertEqual(AppLanguage.pl.displayName, "Polski")
        XCTAssertEqual(AppLanguage.en.displayName, "English")
    }

    func testEveryShippedLanguageHasAFlag() {
        XCTAssertEqual(AppLanguage.pl.flag, "🇵🇱")
        XCTAssertEqual(AppLanguage.en.flag, "🇬🇧")
    }

    /// The picker iterates `allCases` and keys rows by `id`; a duplicate id would collapse rows.
    func testIdentifiersAreTheRawValuesAndAreUnique() {
        XCTAssertEqual(AppLanguage.allCases.map(\.id), ["pl", "en"])
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.id)).count, AppLanguage.allCases.count)
    }
}
