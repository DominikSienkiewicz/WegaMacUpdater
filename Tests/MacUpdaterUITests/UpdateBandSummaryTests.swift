import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// C2 stage 4 — the band after a run: "Sprawdzam wynik" while the check confirms it, then the
/// summary of every planned item until the user closes it. One precedence decides which state
/// the band describes, so no slot mixes two states' words.
@Suite("Band after a run") @MainActor
struct UpdateBandSummaryTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let finishedAt = startedAt.addingTimeInterval(5 * 60)

    // MARK: The check

    private func check(_ checksRunResult: Bool) -> UpdateBandScanPresentation {
        UpdateBandScanPresentation(
            progress: .running(.npm), catalogRefreshing: false, startedAt: Date(timeIntervalSince1970: 0),
            manual: nil, foundSoFar: 5, checksRunResult: checksRunResult
        )
    }

    @Test func theCheckSaysItIsCheckingTheResult() {
        let now = Date(timeIntervalSince1970: 7)
        withLanguage(.pl) {
            let caption = ScanPhaseCopy.caption(progress: .running(.npm), catalogRefreshing: false)
            let checking = check(true)
            #expect(checking.eyebrow(now: now).hasPrefix("Sprawdzam wynik · "))
            #expect(checking.eyebrow(now: now) == "Sprawdzam wynik · 0:07")
            #expect(checking.headline == "Odświeżam listę…")
            #expect(checking.line == caption, "the phase in Wega's words, not the selection note")
            #expect(checking.summary == "Wynik pokażę po sprawdzeniu.")
            #expect(checking.steps == check(false).steps && checking.completedSources == check(false).completedSources,
                    "the chips and the ring stay the scan's")

            let scanning = check(false)
            #expect(scanning.eyebrow(now: now) == "Trwa obchód · 0:07")
            #expect(scanning.headline == caption)
            #expect(scanning.line == tr("Zaznaczanie wróci, gdy skan się skończy."))
            #expect(scanning.summary == trp("%@ aktualizacji", 5) + " " + tr("do tej pory"))
        }
        withLanguage(.en) {
            let checking = check(true)
            #expect(checking.eyebrow(now: now) == "Checking the result · 0:07")
            #expect(checking.headline == "Refreshing the list…")
            #expect(checking.summary == "I'll show the result after the check.")
        }
    }

    // MARK: The summary

    private func item(_ name: String, _ kind: OutdatedItem.Kind) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: kind), name: name, from: "1", to: "2", kind: kind)
    }

    private func report(_ planned: [(OutdatedItem, ItemUpdateVerdict?)], skipped: Set<String> = [],
                        operationID: UUID? = nil) -> UpdateRunReport {
        let outcomes = planned.compactMap { item, verdict in
            verdict.map { ItemUpdateOutcome(key: item.key, name: item.name, kind: item.kind, verdict: $0) }
        }
        return UpdateRunReport.make(
            planned: planned.map(\.0),
            summary: UpdateRunSummary(items: outcomes, diagnostics: [], needsSudoPassword: false),
            skippedKeys: skipped, startedAt: Self.startedAt, finishedAt: Self.finishedAt,
            caskOperationID: operationID, stillOutdatedKeys: [], confirmed: true
        )
    }

    /// Three updated, one failed, two not started (one stopped, one never run).
    private var mixedReport: UpdateRunReport {
        let skipped = item("zeta", .cask)
        return report([
            (item("alpha", .cask), .succeeded), (item("beta", .formula), .succeeded), (item("gamma", .npm), .succeeded),
            (item("delta", .formula), .executionFailed), (skipped, nil), (item("eta", .appStore), nil),
        ], skipped: [skipped.key])
    }

    private func summary(_ report: UpdateRunReport, scanComplete: Bool = true, handOffs: Int = 0,
                         undoExpiry: Date? = nil) -> UpdateBandSummaryPresentation {
        UpdateBandSummaryPresentation(report: report, scanComplete: scanComplete, handOffCount: handOffs, undoExpiry: undoExpiry)
    }

    /// Wega's companion line changes under an open summary — a sidebar click, an undo and its
    /// check ("Wszystko aktualne. Idę się zdrzemnąć."), a language switch. The summary keeps
    /// the run's own line, worded from the report when read.
    @Test func theSummaryKeepsTheRunsOwnLine() throws {
        let planned = [item("alpha", .cask), item("beta", .formula)]
        let finished = report(planned.map { ($0, .succeeded) })
        let stopped = withLanguage(.pl) {
            UpdateRunReport.make(planned: planned, summary: UpdateRunSummary(items: [], diagnostics: [], needsSudoPassword: false),
                                 skippedKeys: Set(planned.map(\.key)), wasStopped: true, finishedAt: Self.finishedAt,
                                 stillOutdatedKeys: [], confirmed: true)
        }
        withLanguage(.pl) {
            #expect(summary(mixedReport).line == "Część pakietów się nie zaktualizowała.")
            #expect(summary(finished).line == trp("Gotowe! %@ pakietów odświeżonych.", 2))
            #expect(summary(stopped).line == "Przerwałam aktualizację.")
            for report in [mixedReport, finished, stopped] {
                #expect(summary(report).line == report.wegaLine)
            }
        }
        withLanguage(.en) {
            #expect(summary(mixedReport).line == "Some packages didn't update.", "re-worded after a language switch")
        }
        let presentation = try source("Sources/MacUpdater/UpdateBandSummaryPresentation.swift")
        #expect(!presentation.contains("let wegaLine"), "no companion line can reach the summary")
        #expect(presentation.contains("var line: String { report.wegaLine }"))
    }

    @Test func theSummaryHeadlineNeverHidesAnIncompleteCheck() {
        withLanguage(.pl) {
            #expect(summary(mixedReport).headline == "Zaktualizowano 3 z 6")
            let incomplete = summary(mixedReport, scanComplete: false)
            #expect(incomplete.headline == "Zaktualizowano 3 z 6 · skan niepełny")
            #expect(incomplete.headline.hasSuffix(" · " + tr("skan niepełny")))
            #expect(incomplete.ringValue == "Zaktualizowano 3 z 6", "the ring says the count, not the note")
            #expect(incomplete.updated == 3 && incomplete.planned == 6)
            #expect(incomplete.line == "Część pakietów się nie zaktualizowała.", "Wega's line from the report")
        }
        withLanguage(.en) {
            #expect(summary(mixedReport, scanComplete: false).headline == "Updated 3 of 6 · " + tr("skan niepełny"))
            #expect(summary(mixedReport).ringValue == "Updated 3 of 6")
        }
    }

    @Test func theSummaryCountsOnlyWhatHappened() {
        let expiry = Self.finishedAt.addingTimeInterval(7 * 86_400)
        withLanguage(.pl) {
            let mixed = summary(mixedReport)
            #expect(mixed.countLines == ["Zaktualizowano: 3", "Nie udało się: 1", "Nie zaczęłam: 2"])
            #expect(mixed.compactCounts == "Nie udało się: 1 · Nie zaczęłam: 2", "the headline already says what was updated")
            #expect(mixed.allCounts == "Zaktualizowano: 3 · Nie udało się: 1 · Nie zaczęłam: 2")
            #expect(mixed.allCounts.hasPrefix("Zaktualizowano: 3"))

            let backedUp = summary(mixedReport, undoExpiry: expiry)
            #expect(backedUp.countLines.first == "Zaktualizowano: 3 · "
                    + trf("kopia do %@", expiry.formatted(.dateTime.day().month(.abbreviated))),
                    "a backup lasts a week, so the band names its day and month")
            #expect(backedUp.countLines.dropFirst() == ["Nie udało się: 1", "Nie zaczęłam: 2"])

            let handedOff = summary(mixedReport, handOffs: 2)
            #expect(handedOff.countLines.last == "U producenta: 2")
            #expect(handedOff.compactCounts == "Nie udało się: 1 · Nie zaczęłam: 2 · U producenta: 2")

            let clean = summary(report([(item("alpha", .cask), .succeeded), (item("beta", .formula), .succeeded),
                                        (item("gamma", .npm), .succeeded)]))
            #expect(clean.compactCounts.isEmpty)
            #expect(clean.countLines == ["Zaktualizowano: 3"])
            #expect(clean.eyebrow.hasPrefix(trp("Zaktualizowano %@ pakietów", 3)), "the success eyebrow")

            let range = Self.startedAt.formatted(date: .omitted, time: .shortened) + "–"
                + Self.finishedAt.formatted(date: .omitted, time: .shortened)
            #expect(mixed.eyebrow == "Aktualizacja niekompletna · " + range)

            let rest = report([
                (item("a", .cask), .rolledBack), (item("b", .formula), .notVerified), (item("c", .npm), .rollbackFailed),
            ])
            #expect(summary(rest).countLines == ["Nie udało się: 1", "Cofnięto: 1", "Bez potwierdzenia: 1"])
        }
        withLanguage(.en) {
            let all = summary(report([
                (item("a", .cask), .succeeded), (item("b", .formula), .executionFailed), (item("c", .cask), .rolledBack),
                (item("d", .npm), .notVerified), (item("e", .formula), nil),
            ]), handOffs: 1)
            #expect(all.countLines == ["Updated: 1", "Failed: 1", "Rolled back: 1", "Not confirmed: 1", "Not started: 1",
                                       "With the developer: 1"])
        }
    }

    /// The backup date the band names is the earliest of this run's undos for the items it
    /// updated: an undo of another run, or of an item that is not updated, is not this run's.
    @Test func theBackupDateIsTheEarliestOfThisRunsUndos() {
        let operation = UUID()
        let planned: [(OutdatedItem, ItemUpdateVerdict?)] = [
            (item("alpha", .cask), .succeeded), (item("beta", .cask), .succeeded), (item("gamma", .cask), .rolledBack),
        ]
        let built = report(planned, operationID: operation)
        func undo(_ token: String, _ days: Double, operationID: UUID) -> UndoableUpdate {
            UndoableUpdate(operationID: operationID, token: token, appPath: "/Applications/\(token).app",
                           restoredVersion: "1", updatedAt: Self.finishedAt,
                           expiresAt: Self.finishedAt.addingTimeInterval(days * 86_400))
        }
        let undoables = [
            undo("alpha", 7, operationID: operation), undo("beta", 5, operationID: operation),
            undo("gamma", 1, operationID: operation), undo("alpha", 2, operationID: UUID()),
        ]
        #expect(UpdateBandSummaryPresentation.earliestUndoExpiry(of: built, in: undoables)
                == Self.finishedAt.addingTimeInterval(5 * 86_400))
        #expect(UpdateBandSummaryPresentation.earliestUndoExpiry(of: built, in: []) == nil)
    }

    // MARK: The band

    private var results: UpdateBandPresentation {
        UpdateBandPresentation(totalCount: 3, urgentCount: 0, queueCount: 1, protectionText: nil, lastCheck: nil,
                               freshness: .fresh, sources: [], wegaLine: "Wega")
    }

    private var run: UpdateBandRunPresentation {
        UpdateBandRunPresentation(progress: UpgradeProgress(completedUnits: 2, totalUnits: 5, stage: .installing(token: nil)),
                                  startedAt: Self.startedAt, isStopping: false, logShown: true)
    }

    @Test func theBandReadsOnePrecedence() throws {
        let band = try source("Sources/MacUpdater/UpdateBand.swift")
        #expect(band.components(separatedBy: "private var mode: UpdateBandMode").count == 2, "one mode, read by every slot")
        for mixed in ["run?.headline ?? scan?.headline", "run?.line ?? scan?.line", "scan?.headline ?? ", "run?.line ?? "] {
            #expect(!band.contains(mixed), "\(mixed)")
        }
        withLanguage(.pl) {
            let checking = check(true)
            let summarised = summary(mixedReport)
            let both = UpdateBandMode.resolve(scan: checking, run: run, summary: summarised)
            #expect(both == .scan(checking), "the check wins over the run it confirms")
            #expect(both.headline(results: results) == checking.headline)
            #expect(both.line(results: results) == checking.line)
            #expect(both.fixedEyebrow == nil, "the check's eyebrow ticks")

            let ran = UpdateBandMode.resolve(scan: nil, run: run, summary: summarised)
            #expect(ran == .run(run))
            #expect(ran.headline(results: results) == run.headline && ran.line(results: results) == run.line)
            #expect(ran.fixedEyebrow == run.eyebrow)

            let summed = UpdateBandMode.resolve(scan: nil, run: nil, summary: summarised)
            #expect(summed == .summary(summarised))
            #expect(summed.headline(results: results) == summarised.headline)
            #expect(summed.line(results: results) == summarised.line)
            #expect(summed.fixedEyebrow == summarised.eyebrow)
            #expect(summed.shortEyebrow == summarised.report.statusTitle, "where the time range does not fit")
            #expect(ran.shortEyebrow == nil && both.shortEyebrow == nil)

            let plain = UpdateBandMode.resolve(scan: nil, run: nil, summary: nil)
            #expect(plain == .results)
            #expect(plain.headline(results: results) == results.headline && plain.line(results: results) == results.line)
            #expect(plain.fixedEyebrow == nil)
        }
        let round = try #require(band.range(of: "private func roundElement(")).upperBound
        let roundBody = band[round...].prefix(900)
        #expect(roundBody.contains("switch mode {"))
        #expect(roundBody.contains("UpdateBandResultRing(updated: summary.updated, planned: summary.planned, diameter: layout.buttonDiameter, accessibilityValue: summary.ringValue)"))
        #expect(band.contains("UpdateBandSummaryControls(summary: summary, compact: false, onClose: onCloseSummary)"))
        #expect(band.contains("fixedEyebrow(fixed, shortened: mode.shortEyebrow)"))
        #expect(band.contains("UpdateBandSummaryControls(summary: summary, compact: true, onClose: onCloseSummary)"))
    }

    @Test func theBandShowsForARunAndItsSummaryEvenWithAnEmptyList() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("private var showsBand: Bool { hasUpdates || scan.updating || scan.runReport != nil }"))
        #expect(view.contains("summary: scan.runReport.map(summaryPresentation)"))
        #expect(view.contains("onCloseSummary: { scan.closeRunReport() }"))
        let scanState = try #require(view.range(of: "private var scanPresentation: UpdateBandScanPresentation {")).upperBound
        let scanBuilder = view[scanState...].prefix(500).replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        // Final review C11 — so is the undo's check while the summary stays open: it promises the
        // result, not a selection the summary does not offer.
        #expect(scanBuilder.contains("checksRunResult: scan.updating || (scan.undoBusy != nil && scan.runReport != nil)"),
                "a scan during a run is the run's check")
        let summaryState = try #require(view.range(of: "private func summaryPresentation(_ report: UpdateRunReport)")).upperBound
        let builderEnd = try #require(view.range(of: "private var runPresentation: UpdateBandRunPresentation", range: summaryState..<view.endIndex))
        let builder = view[summaryState..<builderEnd.lowerBound]
        for input in ["scan.lastScanComplete", "scan.handOffCount(for: .all)",
                      "UpdateBandSummaryPresentation.earliestUndoExpiry(of: report, in: scan.undoableUpdates)"] {
            #expect(builder.contains(input), "\(input)")
        }
        #expect(!builder.contains("wegaLine"), "the summary's line is the report's, not Wega's companion line")
    }

    /// Spec R18 — Wega's ball waited for the danger banners the summary replaces; it now also
    /// waits while an unsuccessful summary is open, or one with a row in „Wymaga uwagi” (final
    /// review C4: a confirmed changed publisher finishes the run, its banner waits for the close).
    @Test func anUnsuccessfulSummaryHoldsWegasBall() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let held = ".wegaAttention(showUpdateConfirmation || scan.pendingForceRestart != nil)"
        let original = try #require(view.range(of: held), "the original hold stays")
        let summaryHold = try #require(view.range(of: ".wegaAttention(scan.runReport?.holdsAttention ?? false)"))
        let between = view[original.upperBound..<summaryHold.lowerBound]
        #expect(between.allSatisfy { $0.isWhitespace }, "right after the original")
        let report = try source("Sources/MacUpdater/UpdateRunReport.swift")
        #expect(report.contains("var holdsAttention: Bool { status != .finished || !entries(in: .needsAttention).isEmpty }"))
    }

    /// Final review C14 — the band switches its colours under Increase Contrast; the result ring's
    /// two shares switch with it, still the palette's dark values (the band is always dark).
    @Test func theResultRingFollowsIncreaseContrast() throws {
        let regular = UpdateBandResultRing.shareColors(increasedContrast: false)
        let raised = UpdateBandResultRing.shareColors(increasedContrast: true)
        #expect(regular.updated == WegaPalette.success.dark && regular.rest == WegaPalette.danger.dark)
        #expect(raised.updated == WegaPalette.success.darkIncreasedContrast, "the updated share")
        #expect(raised.rest == WegaPalette.danger.darkIncreasedContrast, "the rest")
        let views = try source("Sources/MacUpdater/UpdateBandSummaryViews.swift")
        #expect(views.contains("@Environment(\\.colorSchemeContrast) private var contrast"))
        #expect(views.contains("let colors = Self.shareColors(increasedContrast: contrast == .increased)"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
