import AppKit
import Foundation
import MacUpdaterCore
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// Owner, 2026-11-22: the band stays when the scan leaves nothing to update. It used to give way
/// to a plain "Wszystko aktualne" heading, so on an up-to-date Mac it came and went with every
/// scan. Now it says so itself: Wega asleep, the check time and sources, the ↻ button, and a
/// check mark where the update button stands.
@Suite("The band when nothing needs updating") @MainActor
struct UpdateBandUpToDateTests {
    private func presentation(nothingToUpdate: Bool = true, incomplete: Bool = false) -> UpdateBandPresentation {
        var presentation = UpdateBandPresentation(
            totalCount: 0, urgentCount: 0, queueCount: 0, protectionText: nil,
            lastCheck: Date(timeIntervalSince1970: 1_800_000_000), freshness: .stale,
            sources: [
                .init(token: "brew", isVerified: true), .init(token: "mas", isVerified: true),
                .init(token: "npm", isVerified: false), .init(token: "producenci", isVerified: true),
            ],
            wegaLine: "Wszystko aktualne. Idę się zdrzemnąć, a potem jeszcze raz sprawdzę wszystkie źródła.",
            nothingToUpdate: nothingToUpdate
        )
        if incomplete { presentation.incompleteNote = tr("skan niepełny") }
        return presentation
    }

    @Test func onlyACompleteScanCallsTheMacUpToDate() {
        withLanguage(.pl) {
            let complete = presentation()
            #expect(UpdateBandMode.resolve(scan: nil, run: nil, summary: nil, upToDate: complete.nothingToUpdate) == .upToDate)
            #expect(UpdateBandMode.upToDate.headline(results: complete) == "Wszystko aktualne")
            #expect(UpdateBandMode.upToDate.line(results: complete) == complete.wegaLine)
            #expect(UpdateBandMode.upToDate.headline(results: presentation(incomplete: true)) == "Nie wiem, czy wszystko aktualne",
                    "REL-09 — a scan some source did not answer cannot call an empty list up to date")
        }
        withLanguage(.en) {
            #expect(UpdateBandMode.upToDate.headline(results: presentation()) == "Everything up to date")
        }
    }

    @Test func aScanOrARunStillTakesTheBand() {
        let scan = UpdateBandScanPresentation(progress: .running(.brew), catalogRefreshing: false,
                                              startedAt: Date(timeIntervalSince1970: 0), manual: nil, foundSoFar: 0)
        let run = UpdateBandRunPresentation(progress: UpgradeProgress(completedUnits: 0, totalUnits: 1, stage: .downloading(token: "zed")),
                                            startedAt: Date(timeIntervalSince1970: 0), isStopping: false, logShown: false)
        #expect(UpdateBandMode.resolve(scan: scan, run: nil, summary: nil, upToDate: true) == .scan(scan))
        #expect(UpdateBandMode.resolve(scan: nil, run: run, summary: nil, upToDate: true) == .run(run))
        #expect(UpdateBandMode.resolve(scan: nil, run: nil, summary: nil, upToDate: false) == .results)
    }

    @Test func nothingToUpdateLeavesNoQueueToSummarise() {
        #expect(!UpdateBandMode.upToDate.showsSummary, "no „0 w kolejce” and no plan link")
        #expect(UpdateBandMode.results.showsSummary)
        for layout in [UpdateBandLayout.regular, .compact, .narrow] {
            #expect(UpdateBandMode.results.headlineLineLimit(in: layout) == layout.headlineLineLimit, "the results keep their limit")
        }
    }

    /// The mark stands where the button and the scan ring stand, so the ↻ beside it keeps its
    /// place when a scan over an up-to-date Mac ends.
    @Test func theMarkIsExactlyTheButtonsDiameter() {
        for diameter in [WegaLayout.bandButtonSize, WegaLayout.bandButtonCompactSize, WegaLayout.bandButtonNarrowSize] {
            for complete in [true, false] {
                let mark = UpdateBandUpToDateMark(complete: complete, diameter: diameter)
                #expect(NSHostingView(rootView: mark).fittingSize == CGSize(width: diameter, height: diameter),
                        "diameter \(diameter), complete \(complete)")
            }
        }
    }

    @Test func theUpToDateBandKeepsTheBandsHeight() {
        for language in [AppLanguage.pl, .en] {
            for incomplete in [false, true] {
                for width in [240, 368, 388, 480, 520, 819, 820, 1100] as [CGFloat] {
                    let (framed, natural) = withLanguage(language) {
                        let band = UpdateBand(presentation: presentation(incomplete: incomplete), scan: nil,
                                              planLinkEnabled: true, onShowPlan: {},
                                              action: { layout in Color.clear.frame(width: layout.buttonDiameter, height: layout.buttonDiameter) })
                        return (NSHostingView(rootView: band.frame(width: width)).fittingSize.height,
                                NSHostingView(rootView: band.naturalContent(width: width)).fittingSize.height)
                    }
                    #expect(framed == WegaLayout.bandHeight, "\(language), width \(width), incomplete \(incomplete)")
                    #expect(natural <= WegaLayout.bandHeight, "\(language), width \(width), incomplete \(incomplete): \(natural) pt")
                }
            }
        }
    }

    /// The longest headline, the incomplete scan's, within the lines the band allows it at each
    /// layout's narrowest band. With nothing to update there is no summary: the regular text
    /// column is wider, and the compact one has no row under the sentence, so the headline may
    /// wrap further (`theUpToDateBandKeepsTheBandsHeight` checks it still fits the band).
    @Test func theUpToDateHeadlineIsNeverTruncated() {
        let widths: [CGFloat] = [420 - 2 * WegaLayout.listGutter, WegaLayout.bandNarrowBreakpoint, WegaLayout.bandCompactBreakpoint]
        for bandWidth in widths {
            let layout = UpdateBandLayout.style(forWidth: bandWidth)
            let column: CGFloat = switch layout {
            case .narrow:  bandWidth - 2 * 16 - WegaLayout.bandButtonNarrowSize - 12
            case .compact: bandWidth - 2 * 20 - WegaLayout.bandWegaCompactSize - ScanRoundButton.diameter
                - WegaLayout.bandButtonCompactSize - 3 * 14
            case .regular: bandWidth - 2 * 20 - WegaLayout.bandWegaSize - ScanRoundButton.diameter
                - WegaLayout.bandButtonSize - 3 * 20
            }
            for language in [AppLanguage.pl, .en] {
                withLanguage(language) {
                    let headline = UpdateBandMode.upToDate.headline(results: presentation(incomplete: true))
                    let font = Font.wega(layout.headlineStyle, weight: .semibold)
                    let lines = Array(repeating: "A", count: UpdateBandMode.upToDate.headlineLineLimit(in: layout)).joined(separator: "\n")
                    let allowed = NSHostingView(rootView: Text(verbatim: lines).font(font).frame(width: column)).fittingSize.height
                    let needed = NSHostingView(rootView: Text(verbatim: headline).font(font)
                        .frame(width: column).fixedSize(horizontal: false, vertical: true)).fittingSize.height
                    #expect(needed <= allowed, "\(language), band \(bandWidth) pt (\(layout)): „\(headline)” needs \(needed) of \(allowed) pt")
                }
            }
        }
    }

    /// The Updates screen draws the band over every result; the plain heading is gone.
    @Test func theUpdatesScreenAlwaysDrawsTheBand() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let lower = try #require(view.range(of: "private var resultsView: some View")).upperBound
        let upper = try #require(view.range(of: "private var listHeader: some View")).lowerBound
        let results = view[lower..<upper]
        #expect(results.contains("resultsBand"))
        #expect(!results.contains("showsBand") && !view.contains("private var resultsHeading"), "no second heading to switch to")
        #expect(view.contains("nothingToUpdate:   !hasUpdates"), "the band hears what the hero below reads")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
