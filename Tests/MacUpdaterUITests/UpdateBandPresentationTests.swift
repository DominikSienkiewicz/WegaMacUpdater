import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// The band's copy.
@Suite("UpdateBandPresentation")
struct UpdateBandPresentationTests {

    private func presentation(
        total: Int = 3,
        urgent: Int = 0,
        queue: Int = 3,
        lastCheck: Date? = nil,
        freshness: ScanFreshness = .fresh,
        sources: [UpdateBandPresentation.SourceChip] = []
    ) -> UpdateBandPresentation {
        UpdateBandPresentation(
            totalCount: total, urgentCount: urgent, queueCount: queue,
            protectionText: nil, lastCheck: lastCheck, freshness: freshness,
            sources: sources, wegaLine: "Wega"
        )
    }

    @Test func headlinePluralises() {
        withLanguage(.pl) {
            let expected = [0: "0 aktualizacji", 1: "1 aktualizacja", 2: "2 aktualizacje",
                            5: "5 aktualizacji", 12: "12 aktualizacji", 22: "22 aktualizacje"]
            for (total, text) in expected {
                #expect(presentation(total: total).headline == text)
            }
            #expect(presentation(total: 4, urgent: 2).headline == "4 aktualizacje · 2 pilne")
            #expect(!presentation(total: 4, urgent: 0).headline.contains(" · "))
        }
    }

    @Test func urgentPluralises() {
        withLanguage(.pl) {
            for (urgent, text) in [1: "1 pilna", 3: "3 pilne", 5: "5 pilnych"] {
                #expect(presentation(total: 9, urgent: urgent).headline.hasSuffix(" · " + text))
            }
        }
    }

    @Test func staleResultsKeepTheirExplicitDate() {
        withLanguage(.pl) {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let stale = presentation(lastCheck: date, freshness: .stale)
            #expect(stale.freshnessIsExplicit)
            #expect(stale.freshnessText
                == trf("Znaleziono %@", date.formatted(date: .abbreviated, time: .shortened)))
            let fresh = presentation(lastCheck: date, freshness: .fresh)
            #expect(!fresh.freshnessIsExplicit)
            #expect(fresh.freshnessText
                == trf("Sprawdzono %@", date.formatted(date: .omitted, time: .shortened)))
            #expect(presentation(lastCheck: nil).freshnessText == nil)
        }
    }

    /// Hours-old results keep today's heading wording, "Sprawdzono" and a time; only a stale
    /// snapshot names its date. They are still drawn in the accent colour.
    @Test func recentResultsSayCheckedInTheAccentColour() {
        withLanguage(.pl) {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let recent = presentation(lastCheck: date, freshness: .recent)
            #expect(recent.freshnessIsExplicit)
            #expect(recent.freshnessText
                == trf("Sprawdzono %@", date.formatted(date: .omitted, time: .shortened)))
        }
    }

    @Test func anEmptyQueueSaysSo() {
        withLanguage(.pl) {
            let empty = presentation(queue: 0)
            #expect(empty.buttonTitle == tr("Kolejka pusta"))
            #expect(empty.buttonCount == nil)
            #expect(!empty.showsPlanLink)
            #expect(empty.queueSummary == trf("%@ w kolejce", "0"))
            let queued = presentation(queue: 3)
            #expect(queued.buttonTitle == tr("Aktualizuj"))
            #expect(queued.buttonCount == 3)
            #expect(queued.showsPlanLink)
            #expect(queued.buttonAccessibilityLabel == trf("Zaktualizuj wybrane (%@)", "3"))
            #expect(queued.buttonTitle == "Aktualizuj")
            #expect(empty.buttonTitle == "Kolejka pusta")
            #expect(queued.queueSummary == "3 w kolejce")
        }
    }

    /// A source that failed still took part in the scan, so it keeps its token, but only a
    /// source that answered is checked.
    @Test func onlySourcesThatAnsweredAreChecked() {
        let answered = ScanSourceReport(outcome: .succeeded)
        let reports = ScanSourceReports(
            brew: answered, mas: answered,
            npm: ScanSourceReport(outcome: .failed("npm"), error: "timeout"), manual: answered
        )
        let chips = UpdateBandPresentation.SourceChip.chips(from: reports)
        #expect(chips == [
            .init(token: SourceCommunication.stampToken(.homebrew), isVerified: true),
            .init(token: SourceCommunication.stampToken(.appStore), isVerified: true),
            .init(token: SourceCommunication.stampToken(.npm), isVerified: false),
            .init(token: SourceCommunication.stampToken(.manual), isVerified: true),
        ])
        #expect(presentation(sources: chips).sourceChips == chips)
    }

    /// With no per-source detail the band names every source Wega checks and checks none.
    @Test func withoutPerSourceDetailNoSourceIsChecked() {
        let chips = UpdateBandPresentation.SourceChip.chips(from: ScanSourceReports())
        #expect(chips.map(\.token) == ScanSource.allCases.map(SourceCommunication.stampToken))
        #expect(chips.allSatisfy { !$0.isVerified })
    }

    @Test func englishPlurals() {
        withLanguage(.en) {
            #expect(presentation(total: 1).headline == "1 update")
            #expect(presentation(total: 2).headline == "2 updates")
            #expect(presentation(total: 5, urgent: 2).headline.hasSuffix("2 urgent"))
            #expect(presentation(queue: 0).queueSummary == "0 queued")
            #expect(presentation(queue: 0).buttonTitle == "Queue empty")
            #expect(presentation(queue: 3).buttonTitle == "Update")
            #expect(presentation(queue: 3).queueSummary == "3 queued")
        }
    }
}
