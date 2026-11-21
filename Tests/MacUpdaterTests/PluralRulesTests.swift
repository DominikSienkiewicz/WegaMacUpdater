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

    /// Final review M4 — the release-notes history's tail counts the releases it leaves out.
    @Test(arguments: zip([1, 2, 5, 12, 22], ["…i 1 wcześniejsze wydanie", "…i 2 wcześniejsze wydania",
                                             "…i 5 wcześniejszych wydań", "…i 12 wcześniejszych wydań",
                                             "…i 22 wcześniejsze wydania"]))
    func theOmittedReleasesAgree(count: Int, expected: String) {
        #expect(pluralize("…i %@ wcześniejszych wydań", count: count, language: .pl) == expected)
    }

    @Test func theOmittedReleasesAgreeInEnglish() {
        #expect(pluralize("…i %@ wcześniejszych wydań", count: 1, language: .en) == "…and 1 earlier release")
        #expect(pluralize("…i %@ wcześniejszych wydań", count: 2, language: .en) == "…and 2 earlier releases")
        #expect(pluralize("…i %@ wcześniejszych wydań", count: 22, language: .en) == "…and 22 earlier releases")
    }

    @Test func unregisteredBaseHasNoPluralForms() {
        #expect(pluralize("Brak wariantów %@", count: 1, language: .pl) == nil)
    }

    @Test(arguments: zip([1, 2, 5, 12, 22], ["Zaktualizować 1 pozycję?", "Zaktualizować 2 pozycje?",
          "Zaktualizować 5 pozycji?", "Zaktualizować 12 pozycji?", "Zaktualizować 22 pozycje?"]))
    func theConfirmationCountsItsItems(count: Int, expected: String) {
        #expect(pluralize("Zaktualizować %@ pozycji?", count: count, language: .pl) == expected)
    }

    @Test func everyRoundTwoNounAgrees() {
        #expect(pluralize("%@ resztek do Kosza", count: 1, language: .pl) == "1 resztka do Kosza")
        #expect(pluralize("Nie udało się przenieść %@ resztek do Kosza.", count: 1, language: .pl)
                == "Nie udało się przenieść 1 resztkę do Kosza.")
        #expect(pluralize("Zaktualizowano %@ pakietów", count: 22, language: .pl) == "Zaktualizowano 22 pakiety")
        #expect(pluralize("Zaktualizowano %@ pakietów", count: 12, language: .pl) == "Zaktualizowano 12 pakietów")
        #expect(pluralize("Odinstalować %@ aplikacji?", count: 3, language: .pl) == "Odinstalować 3 aplikacje?")
        #expect(pluralize("%@ aplikacji nie jest zarządzanych przez Homebrew — trafią do Kosza.", count: 1, language: .pl)
                == "1 aplikacja nie jest zarządzana przez Homebrew — trafi do Kosza.")
        #expect(pluralize("Znalazłam %@ rzeczy do uporządkowania.", count: 1, language: .pl)
                == "Znalazłam 1 rzecz do uporządkowania.")
        #expect(pluralize("%@ źródeł nie odpowiedziało", count: 2, language: .pl) == "2 źródła nie odpowiedziały")
        #expect(pluralize("Zaktualizować %@ pozycji?", count: 1, language: .en) == "Update 1 item?")
        #expect(pluralize("Zaktualizowano %@ pakietów", count: 1, language: .en) == "Updated 1 package")
        #expect(pluralize("%@ źródeł nie odpowiedziało", count: 1, language: .en) == "1 source didn't respond")
        #expect(pluralize("Odinstalować %@ aplikacji?", count: 22, language: .en) == "Uninstall 22 apps?")
    }
}
