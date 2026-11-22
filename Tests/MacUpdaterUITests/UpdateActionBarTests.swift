import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UX-14 — the Updates screen spread one flow over three places: a select-all row above the
/// list, the update button in the results header and the plan in a disclosure between them.
/// One bar under the list now carries the selection, the rollback coverage, the plan and the
/// update itself.
@Suite("Update action bar")
@MainActor
struct UpdateActionBarTests {
    @Test func anEmptySelectionAsksForOne() {
        let summary = UpdateActionBarSummary(selectedCount: 0, visibleCount: 3, targets: [], protection: [:])

        #expect(summary.selectionText == tr("Zaznacz, co mam zaktualizować"))
        #expect(summary.protectionText == nil, "nothing ticked means nothing to cover")
    }

    @Test func theSelectionIsCountedAgainstTheVisibleRows() {
        let summary = UpdateActionBarSummary(selectedCount: 2, visibleCount: 5, targets: [], protection: [:])

        #expect(summary.selectionText == trf("%@ z %@ zaznaczonych", "2", "5"))
    }

    /// The bar may only promise the rollback net for what the net really covers: ticked casks
    /// whose verdict is `.protected`. A formula never qualifies, whatever a stray map entry says.
    @Test func onlyProtectedCaskTargetsCountAsCoveredByRollback() {
        let targets = [
            OutdatedItem(key: "c:firefox", name: "firefox", from: "1", to: "2", kind: .cask),
            OutdatedItem(key: "c:raycast", name: "raycast", from: "1", to: "2", kind: .cask),
            OutdatedItem(key: "f:wget", name: "wget", from: "1", to: "2", kind: .formula),
        ]
        let protection: [String: RollbackProtection.Verdict] = [
            "firefox": .protected,
            "raycast": .unprotected(.noAppBundle),
            "wget": .protected,
        ]

        let summary = UpdateActionBarSummary(
            selectedCount: 3, visibleCount: 3, targets: targets, protection: protection
        )

        #expect(summary.protectedCount == 1)
        #expect(summary.protectionText == trf("Cofnięcie: %@ z %@", "1", "3"))
    }

    private var firefox: OutdatedItem { OutdatedItem(key: "c:firefox", name: "firefox", from: "1", to: "2", kind: .cask) }
    private var raycast: OutdatedItem { OutdatedItem(key: "c:raycast", name: "raycast", from: "1", to: "2", kind: .cask) }
    private var slack: OutdatedItem { OutdatedItem(key: "c:slack", name: "slack", from: "1", to: "2", kind: .cask) }
    private var wget: OutdatedItem { OutdatedItem(key: "f:wget", name: "wget", from: "1", to: "2", kind: .formula) }

    @Test func undoCoverageIsCountedAgainstTheWholeQueue() {
        let s = UpdateActionBarSummary(selectedCount: 3, visibleCount: 3, targets: [firefox, raycast, wget],
                                       protection: ["firefox": .protected, "raycast": .unprotected(.noAppBundle), "wget": .protected])
        #expect(s.protectionText == trf("Cofnięcie: %@ z %@", "1", "3"))
        withLanguage(.en) { #expect(s.protectionText == "Undo: 1 of 3") }
    }

    @Test func aCaskWithoutAVerdictIsNeverShownAsProtected() {
        let s = UpdateActionBarSummary(selectedCount: 2, visibleCount: 2, targets: [firefox, slack],
                                       protection: ["firefox": .protected])
        #expect(s.protectionText == tr("Sprawdzam możliwość cofnięcia"))
    }

    /// M2 — once the check has finished, a cask it found no verdict for is not covered: the band
    /// stops saying it is still checking, and never counts that cask as protected.
    @Test func aCaskTheFinishedCheckFoundNoVerdictForIsNotProtected() {
        let s = UpdateActionBarSummary(selectedCount: 2, visibleCount: 2, targets: [firefox, slack],
                                       protection: ["firefox": .protected], resolved: ["firefox", "slack"])
        #expect(s.protectionText == trf("Cofnięcie: %@ z %@", "1", "2"))
        let unchecked = UpdateActionBarSummary(selectedCount: 2, visibleCount: 2, targets: [firefox, slack],
                                               protection: ["firefox": .protected], resolved: ["firefox"])
        #expect(unchecked.protectionText == tr("Sprawdzam możliwość cofnięcia"), "a cask the check has not reached")
    }

    /// M2 — `brew info --cask` failing, or answering without one of the casks, used to leave the
    /// band saying "Sprawdzam możliwość cofnięcia" for good. The check records what it asked
    /// about, so those casks settle as not covered.
    @Test(arguments: [false, true])
    func aCheckThatFailsOrMissesACaskSettlesAsNotProtected(infoFails: Bool) async throws {
        let token = "m2-cask-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            guard request.arguments.starts(with: ["info", "--cask"]) else { throw StubError.unexpected(request.arguments) }
            if infoFails { throw StubError.unexpected(request.arguments) }
            return ProcessResult(exitCode: 0, stdout: #"{"casks":[]}"#, stderr: "")
        }
        let store = makeScanStoreRuntimeHarness(runner: runner).store
        store.brewOutdated = BrewOutdated(formulae: [], casks: [BrewOutdatedItem(name: token, installedVersions: ["1"], currentVersion: "2")])

        await store.resolveRollbackProtection()

        #expect(store.caskProtection[token] == nil)
        #expect(store.caskProtectionResolved == [token])
        let cask = OutdatedItem(key: "c:\(token)", name: token, from: "1", to: "2", kind: .cask)
        let summary = UpdateActionBarSummary(selectedCount: 1, visibleCount: 1, targets: [cask],
                                             protection: store.caskProtection, resolved: store.caskProtectionResolved)
        #expect(summary.protectionText == trf("Cofnięcie: %@ z %@", "0", "1"))
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("resolved:      scan.caskProtectionResolved"))
    }

    private enum StubError: Error {
        case unexpected([String])
    }

    @Test func theUpdateButtonLivesInTheBand() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let band = try slice(view, from: "private var resultsBand: some View", to: "private var screenBody: some View")

        let screen = try slice(view, from: "private var resultsView: some View", to: "private var listHeader: some View")
        let listHeader = try slice(view, from: "private var listHeader: some View", to: "private var resultsBand: some View")
        for (name, part) in [("resultsView", screen), ("listHeader", listHeader)] {
            #expect(!part.contains("requestUpdate"), "only the band starts an update, not \(name)")
        }
        #expect(band.contains("UpdateBandButton("))
        #expect(band.contains("action: requestUpdate"))
        #expect(!(try source("Sources/MacUpdater/UpdateBand.swift")).contains("SelectionCheckbox("),
                "the band carries the update, not the selection")
        #expect(band.contains(".disabled(!allowsUpdateRun)"))
        #expect(band.contains(".help(updateButtonHelp)"))
        let bandBody = try slice(view, from: "private var resultsBand: some View", to: "private var bandPresentation:")
        #expect(bandBody.contains("let presentation = bandPresentation"))
        #expect(bandBody.components(separatedBy: "bandPresentation").count == 2, "the band reads one presentation")
        #expect(!view.contains("private var actionBar"), "the bar under the list is gone")
        #expect(!view.contains(".safeAreaInset(edge: .bottom, spacing: 0) { actionBar }"))
        let header = try slice(view, from: "private var listHeader: some View", to: "private var resultsBand: some View")
        #expect(header.contains("SelectionCheckbox("), "the list header carries the list-wide queue circle")
        #expect(header.contains("QueueColumnPlaceholder()"),
                "with nothing to select the header keeps the column so the scope bar stays put")
    }

    @Test func thePlanOpensFromTheBandAsASheet() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let band = try slice(view, from: "private var resultsBand: some View", to: "private var screenBody: some View")

        #expect(band.contains("scan.showPlanPreview = true"))
        #expect(view.contains(".sheet(isPresented: $scan.showPlanPreview)"))
        #expect(!view.contains("WegaDisclosure(isExpanded: $scan.showPlanPreview)"),
                "the plan no longer pushes the list down from inside the screen")
        #expect(band.contains("planLinkEnabled: ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating)"),
                "a running update owns the screen, the plan preview included")
    }

    /// During a run the button is disabled because the run owns the screen, not because the
    /// selection is empty, so the tooltip names the run first.
    @Test func theTooltipNamesARunningUpdateFirst() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let help = try slice(view, from: "private var updateButtonHelp: String", to: "var body: some View")
        let updating = try #require(help.range(of: "if scan.updating { return tr(\"Aktualizuję wybrane pakiety\") }"))
        let refreshing = try #require(help.range(of: "scan.isRefreshing"))
        #expect(updating.lowerBound < refreshing.lowerBound)
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> Substring {
        let lower = try #require(source.range(of: start)?.lowerBound, "missing anchor: \(start)")
        let upper = try #require(
            source.range(of: end, range: lower..<source.endIndex)?.lowerBound, "missing anchor: \(end)"
        )
        return source[lower..<upper]
    }
}
