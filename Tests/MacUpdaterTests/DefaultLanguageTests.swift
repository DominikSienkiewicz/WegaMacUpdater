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
