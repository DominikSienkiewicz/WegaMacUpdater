import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Unconfirmed cask association presentation", .serialized)
struct UnconfirmedCaskPresentationTests {
    private let app = ApplicationInfo(path: URL(fileURLWithPath: "/Fixtures/Example.app"), name: "Example",
                                      bundleIdentifier: "fixture.example", version: "1", installDate: nil,
                                      updateDate: nil, isManagedByBrew: false)

    @Test func testUnconfirmedAssociationHasAnExplicitTitleAndNeedsAttention() {
        var check = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .notChecked)], checkedAt: Date())
        check.unconfirmedCaskToken = "google-drive"
        let presentation = InventoryCheckPresentation(app: app, check: check, policies: [:])
        #expect(presentation.title == tr("Powiązanie z Homebrew niepotwierdzone"))
        #expect(presentation.status == .notChecked)
        #expect(presentation.needsAttention)
        #expect(check.caskToken == nil)
    }

    @Test func testTheNoteDoesNotHideAnUpdateFailureOrStaleResult() {
        let now = Date()
        for (sources, time, expected) in [
            ([InstallationSourceCheck(source: "Sparkle", outcome: .outdated)], now, InstallationCheckStatus.updateAvailable),
            ([InstallationSourceCheck(source: "Sparkle", outcome: .failed)], now, InstallationCheckStatus.failed),
            ([InstallationSourceCheck(source: "Homebrew", outcome: .notChecked)], now.addingTimeInterval(-90_000), InstallationCheckStatus.stale)
        ] {
            var check = InstallationCheck(app: app, sources: sources, checkedAt: time)
            check.unconfirmedCaskToken = "google-drive"
            let presentation = InventoryCheckPresentation(app: app, check: check, policies: [:], now: now)
            #expect(presentation.status == expected)
            #expect(presentation.title != tr("Powiązanie z Homebrew niepotwierdzone"))
        }
    }

    @Test func testTheNewExplanationHasAnEnglishTranslation() {
        #expect(Translations.en["Powiązanie z Homebrew niepotwierdzone"] != nil)
        #expect(Translations.en["Możliwe źródło: Homebrew (%@)"] != nil)
        #expect(Translations.en["Brak jednoznacznego potwierdzenia tej instalacji. Wynik casku nie potwierdza aktualności tej kopii."] != nil)
    }
}
