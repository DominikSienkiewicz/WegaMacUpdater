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
        handOff: Int = 0,
        lastCheck: Date? = nil,
        freshness: ScanFreshness = .fresh,
        sources: [UpdateBandPresentation.SourceChip] = [],
        catalogAge: Int? = nil
    ) -> UpdateBandPresentation {
        UpdateBandPresentation(
            totalCount: total, urgentCount: urgent, queueCount: queue,
            protectionText: nil, lastCheck: lastCheck, freshness: freshness,
            sources: sources, wegaLine: "Wega", handOffCount: handOff, catalogAgeMinutes: catalogAge
        )
    }

    @Test func theCatalogNoteNamesItsAge() {
        withLanguage(.pl) {
            #expect(presentation(catalogAge: 12).catalogNote == "katalog Homebrew sprzed 12 min")
            #expect(presentation().catalogNote == nil)
        }
        withLanguage(.en) { #expect(presentation(catalogAge: 12).catalogNote == "Homebrew catalog from 12 min ago") }
    }

    @Test func anIncompleteScanSaysSoInTheHeadline() {
        withLanguage(.pl) {
            var p = presentation(total: 3, urgent: 1)
            p.incompleteNote = tr("sprawdzenie niepełne")
            // M3 — the note follows the count, so truncation never takes it first.
            #expect(p.headline == "3 aktualizacje · sprawdzenie niepełne · 1 z możliwą poprawką bezp.")
        }
    }

    @Test func headlinePluralises() {
        withLanguage(.pl) {
            let expected = [0: "0 aktualizacji", 1: "1 aktualizacja", 2: "2 aktualizacje",
                            5: "5 aktualizacji", 12: "12 aktualizacji", 22: "22 aktualizacje"]
            for (total, text) in expected {
                #expect(presentation(total: total).headline == text)
            }
            #expect(presentation(total: 4, urgent: 2).headline == "4 aktualizacje · 2 z możliwą poprawką bezp.")
            #expect(!presentation(total: 4, urgent: 0).headline.contains(" · "))
        }
    }

    @Test func urgentPluralises() {
        withLanguage(.pl) {
            for (urgent, text) in [1: "1 z możliwą poprawką bezp.", 3: "3 z możliwą poprawką bezp.", 5: "5 z możliwą poprawką bezp."] {
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

    @Test func theQueueSummaryNamesWhatTheDeveloperFinishes() {
        withLanguage(.pl) {
            #expect(presentation(queue: 4, handOff: 2).queueSummary == "4 w kolejce · 2 dokończysz u producenta")
            #expect(presentation(queue: 4).queueSummary == "4 w kolejce")
        }
        withLanguage(.en) {
            #expect(presentation(queue: 4, handOff: 2).queueSummary == "4 queued · 2 to finish with the developer")
        }
    }

    /// M1 — hand-off apps are never queued, so with nothing queued "0 w kolejce · 3 dokończysz"
    /// read as if the three were. The second half shows only next to a queue.
    @Test func anEmptyQueueNamesNoHandOffs() {
        withLanguage(.pl) { #expect(presentation(queue: 0, handOff: 3).queueSummary == "0 w kolejce") }
        withLanguage(.en) { #expect(presentation(queue: 0, handOff: 3).queueSummary == "0 queued") }
    }

    /// M1 — the hand-offs the band counts are the ones the category on screen lists: every
    /// manual row under All and Apps, the security-flagged ones under Security, none under CLI.
    @MainActor @Test func theHandOffsAreCountedInTheCategoryOnScreen() throws {
        let harness = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        })
        let app = ManualOutdatedApp(
            name: "Hand Off", path: URL(fileURLWithPath: "/Applications/HandOff-\(UUID().uuidString).app"),
            installedVersion: "1", availableVersion: "2", source: .sparkle,
            bundleIdentifier: "example.handoff.\(UUID().uuidString)"
        )
        harness.store.manualOutdated = [app]
        #expect(harness.store.handOffCount(for: .all) == 1)
        #expect(harness.store.handOffCount(for: .apps) == 1)
        #expect(harness.store.handOffCount(for: .cli) == 0, "no manual app is a CLI tool")
        #expect(harness.store.handOffCount(for: .security) == 0, "its notes mention no security fix")
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("handOffCount:   scan.handOffCount(for: updateFilter)"))
    }

    @Test func anEmptyButtonSaysNothingIsSelectedAndVoiceOverReadsTheSame() {
        withLanguage(.pl) {
            let empty = presentation(queue: 0)
            #expect(empty.buttonTitle == "Nic nie zaznaczono")
            #expect(empty.buttonAccessibilityLabel == empty.buttonTitle)
            #expect(presentation(queue: 3).buttonAccessibilityLabel == trf("Zaktualizuj wybrane (%@)", "3"))
        }
        withLanguage(.en) { #expect(presentation(queue: 0).buttonTitle == "Nothing selected") }
    }

    @Test func anEmptyQueueSaysSo() {
        withLanguage(.pl) {
            let empty = presentation(queue: 0)
            #expect(empty.buttonTitle == tr("Nic nie zaznaczono"))
            #expect(empty.buttonCount == nil)
            #expect(!empty.showsPlanLink)
            #expect(empty.queueSummary == trf("%@ w kolejce", "0"))
            let queued = presentation(queue: 3)
            #expect(queued.buttonTitle == tr("Aktualizuj"))
            #expect(queued.buttonCount == 3)
            #expect(queued.showsPlanLink)
            #expect(queued.buttonAccessibilityLabel == trf("Zaktualizuj wybrane (%@)", "3"))
            #expect(queued.buttonTitle == "Aktualizuj")
            #expect(empty.buttonTitle == "Nic nie zaznaczono")
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
            #expect(presentation(total: 5, urgent: 2).headline.hasSuffix("2 may fix security issues"))
            #expect(presentation(queue: 0).queueSummary == "0 queued")
            #expect(presentation(queue: 0).buttonTitle == "Nothing selected")
            #expect(presentation(queue: 3).buttonTitle == "Update")
            #expect(presentation(queue: 3).queueSummary == "3 queued")
        }
    }

    private enum StubError: Error {
        case unexpected([String])
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
