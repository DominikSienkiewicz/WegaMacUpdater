import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-13 — the band while a scan runs in place: the phase in the headline, the time the patrol
/// has taken in the eyebrow, the vendor count (never an ETA) in the line, and what the scan has
/// found so far in the summary.
@Suite("Band while scanning") @MainActor
struct UpdateBandScanPresentationTests {
    private func p(_ progress: ScanProgress?, catalog: Bool = false, manual: ManualScanProgress? = nil, found: Int = 5)
        -> UpdateBandScanPresentation {
        .init(progress: progress, catalogRefreshing: catalog, startedAt: Date(timeIntervalSince1970: 0), manual: manual, foundSoFar: found)
    }

    @Test func theCaptionFollowsThePhase() {
        withLanguage(.pl) {
            #expect(p(.running(.brew), catalog: true).headline == "Odświeżam katalog Homebrew…")
            #expect(p(.running(.brew)).headline == "Wega węszy po Homebrew…")
            #expect(p(.running(.mas)).headline == "Wega węszy w App Store…")
            #expect(p(.running(.npm)).headline == "Wega węszy w npm…")
            #expect(p(.running(.manual)).headline == "Wega węszy u producentów…")
        }
        withLanguage(.en) {
            #expect(p(.running(.brew), catalog: true).headline == "Refreshing the Homebrew catalog…")
            #expect(p(.running(.manual)).headline == "Wega is sniffing around the developers' sites…")
        }
    }

    /// The first scan's scene and the band say the same thing, from one function.
    @Test func theFirstScanSceneUsesTheSameCaption() throws {
        withLanguage(.pl) {
            #expect(ScanPhaseCopy.caption(progress: .running(.npm), catalogRefreshing: false) == "Wega węszy w npm…")
            #expect(ScanPhaseCopy.caption(progress: nil, catalogRefreshing: false) == "Wega węszy po Homebrew…",
                    "before the first phase lands the scan is about to ask Homebrew")
        }
        let scene = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacUpdater/ScanBusyOverlay.swift"), encoding: .utf8)
        #expect(scene.contains("caption: ScanPhaseCopy.caption(progress: progress, catalogRefreshing: catalogRefreshing)"))
        #expect(!scene.contains("caption: tr(\"Wega węszy po Homebrew…\")"), "the caption no longer stands still")
    }

    @Test func theLineCountsVendorAppsWithoutAnETA() {
        withLanguage(.pl) {
            #expect(p(.running(.manual), manual: .init(checkedApps: 12, totalApps: 31)).line == "Producenci: 12 z 31 aplikacji")
            #expect(p(.running(.manual), manual: .init(checkedApps: 0, totalApps: 1)).line == "Producenci: 0 z 1 aplikacji")
            #expect(p(.running(.manual), manual: .init(checkedApps: 2, totalApps: 22)).line == "Producenci: 2 z 22 aplikacji")
            #expect(p(.running(.npm)).line == tr("Zaznaczanie wróci, gdy skan się skończy."))
        }
        withLanguage(.en) {
            #expect(p(.running(.manual), manual: .init(checkedApps: 0, totalApps: 1)).line == "Vendors: 0 of 1 app")
            #expect(p(.running(.manual), manual: .init(checkedApps: 12, totalApps: 31)).line == "Vendors: 12 of 31 apps")
            #expect(p(.running(.manual), manual: .init(checkedApps: 1, totalApps: 2)).line == "Vendors: 1 of 2 apps")
        }
    }

    @Test func theEyebrowShowsElapsedTimeAndTheRingCountsSources() {
        #expect(UpdateBandScanPresentation.elapsed(from: .init(timeIntervalSince1970: 0), to: .init(timeIntervalSince1970: 42)) == "0:42")
        #expect(UpdateBandScanPresentation.elapsed(from: .init(timeIntervalSince1970: 0), to: .init(timeIntervalSince1970: 725)) == "12:05")
        withLanguage(.pl) {
            #expect(p(.running(.npm)).eyebrow(now: .init(timeIntervalSince1970: 7)) == "Trwa obchód · 0:07")
            #expect(p(.running(.npm)).completedSources == 2 && p(.running(.npm)).totalSources == 4)
            #expect(p(.running(.npm)).ringAccessibilityValue == "2 z 4 źródeł")
            for (n, text) in [1: "1 aktualizacja do tej pory", 2: "2 aktualizacje do tej pory", 5: "5 aktualizacji do tej pory",
                              12: "12 aktualizacji do tej pory", 22: "22 aktualizacje do tej pory"] {
                #expect(p(.running(.npm), found: n).summary == text)
            }
        }
        withLanguage(.en) {
            #expect(p(.running(.npm), found: 1).summary == "1 update so far")
            #expect(p(.running(.npm), found: 2).summary == "2 updates so far")
            #expect(p(.running(.npm)).eyebrow(now: .init(timeIntervalSince1970: 7)) == "Patrol in progress · 0:07")
            #expect(p(.running(.npm)).ringAccessibilityValue == "2 of 4 sources")
        }
    }

    /// The ring and the chips read the strip's own phase rule, so the band cannot claim a
    /// source the scan has not reached.
    @Test func theRingAndTheChipsFollowTheStrip() {
        for progress: ScanProgress? in [nil, .running(.brew), .running(.manual), .cancelled(at: .mas), .finished] {
            #expect(p(progress).steps == ScanPhaseStrip.steps(for: progress))
        }
        #expect(p(.running(.brew)).completedSources == 0)
        #expect(p(.running(.manual)).completedSources == 3)
    }
}
