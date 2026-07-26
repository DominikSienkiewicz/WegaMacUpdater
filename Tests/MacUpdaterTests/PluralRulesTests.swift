import Testing
import Foundation
@testable import MacUpdaterCore

/// UX-08 — regression coverage for the plural engine behind `trp(base, count)`.
///
/// The menu-bar counter used to read literally „1 aktualizacji dostępnych" (and, in the
/// English UI, „1 updates available") because one hard form carried every count. These
/// tests pin the Polish grammar rule — one · few (2–4 except 12–14) · many — and the
/// English one/other collapse, across the number ranges the card calls out.
@Suite("PluralRules")
struct PluralRulesTests {

    private let updatesAvailable = "%@ aktualizacji dostępnych"

    @Test func polishCategoryFollowsTheOneFewManyRule() {
        #expect(polishPluralCategory(1) == .one)

        for count in [2, 3, 4, 22, 23, 24, 102, 103, 104] {
            #expect(polishPluralCategory(count) == .few, "\(count) should be few")
        }

        for count in [0, 5, 6, 9, 10, 11, 12, 13, 14, 15, 20, 21, 25, 100, 111, 112, 113, 114] {
            #expect(polishPluralCategory(count) == .many, "\(count) should be many")
        }
    }

    @Test func polishFormsAreGrammaticalForEveryRange() {
        #expect(pluralize(updatesAvailable, count: 1, language: .pl) == "1 aktualizacja dostępna")
        #expect(pluralize(updatesAvailable, count: 3, language: .pl) == "3 aktualizacje dostępne")
        #expect(pluralize(updatesAvailable, count: 22, language: .pl) == "22 aktualizacje dostępne")
        #expect(pluralize(updatesAvailable, count: 13, language: .pl) == "13 aktualizacji dostępnych")
        #expect(pluralize(updatesAvailable, count: 5, language: .pl) == "5 aktualizacji dostępnych")
        #expect(pluralize(updatesAvailable, count: 0, language: .pl) == "0 aktualizacji dostępnych")
    }

    @Test func englishCollapsesToSingularAndPlural() {
        #expect(pluralize(updatesAvailable, count: 1, language: .en) == "1 update available")
        #expect(pluralize(updatesAvailable, count: 2, language: .en) == "2 updates available")
        #expect(pluralize(updatesAvailable, count: 13, language: .en) == "13 updates available")
        #expect(pluralize(updatesAvailable, count: 5, language: .en) == "5 updates available")
    }

    @Test func unregisteredBaseHasNoPluralForms() {
        #expect(pluralize("Brak wariantów %@", count: 1, language: .pl) == nil)
    }
}
