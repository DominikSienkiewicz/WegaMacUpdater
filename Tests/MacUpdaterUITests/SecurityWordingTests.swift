import Foundation
import Testing
@testable import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Security wording") @MainActor
struct SecurityWordingTests {
    @Test func theBandSaysPossibleNotUrgent() {
        LocalizedStrings.withScopedLanguage(.pl) {
            #expect(trp("%@ z możliwą poprawką bezp.", 2) == "2 z możliwą poprawką bezp.")
        }
        LocalizedStrings.withScopedLanguage(.en) {
            #expect(trp("%@ z możliwą poprawką bezp.", 1) == "1 may fix a security issue")
            #expect(trp("%@ z możliwą poprawką bezp.", 5) == "5 may fix security issues")
        }
    }

    @Test func theInspectorNamesTheWordsThatMatched() {
        #expect(ReleaseTriageReason.text(signals: ["cve-", "exploit"])
                == trf("Wega znalazła w notatkach: %@", "„cve-”, „exploit”"))
        #expect(ReleaseTriageReason.text(signals: []) == nil)
    }

    @Test func wegaDoesNotCallAKeywordUrgent() {
        #expect(WegaCompanionPresentation.finishedQuip(updateCount: 3, securityCount: 2, scanComplete: true)
                == trp("Notatki %@ wydań wspominają o bezpieczeństwie.", 2))
    }

    @Test func theWordsAreInTheActiveLanguageAndPluralised() {
        LocalizedStrings.withScopedLanguage(.pl) {
            #expect(WegaCompanionPresentation.finishedQuip(updateCount: 3, securityCount: 1, scanComplete: true)
                    == "Notatki jednego wydania wspominają o bezpieczeństwie.")
            #expect(WegaCompanionPresentation.finishedQuip(updateCount: 9, securityCount: 22, scanComplete: true)
                    == "Notatki 22 wydań wspominają o bezpieczeństwie.")
        }
        LocalizedStrings.withScopedLanguage(.en) {
            #expect(WegaCompanionPresentation.finishedQuip(updateCount: 3, securityCount: 1, scanComplete: true)
                    == "One release note mentions security.")
            #expect(WegaCompanionPresentation.finishedQuip(updateCount: 3, securityCount: 12, scanComplete: true)
                    == "12 release notes mention security.")
        }
    }
}
