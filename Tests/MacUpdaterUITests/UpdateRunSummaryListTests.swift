import AppKit
import Foundation
import MacUpdaterCore
import SwiftUI
import Testing
import XCTest

@testable import WegaMacUpdater

/// C2 stage 4 — while a report is open the list shows the run's result instead of the rows: one
/// sentence per row, only the actions the report allows, nothing to queue or inspect, the
/// hand-offs the band counts, and neither ⇧⌘A nor ⌘⏎ reaching the rows the summary hides.
@Suite("Run summary list") @MainActor
struct UpdateRunSummaryListTests {
    private enum StubError: Error { case unexpected([String]) }

    private static let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let operationID = UUID()
    private static let summaryFile = "Sources/MacUpdater/UpdateRunSummaryList.swift"

    private func cask(_ name: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: .cask), name: name, from: "1", to: "2", kind: .cask)
    }

    private func report(_ planned: [OutdatedItem], _ verdicts: [ItemUpdateVerdict]) -> UpdateRunReport {
        let outcomes = zip(planned, verdicts).map { ItemUpdateOutcome(key: $0.key, name: $0.name, kind: $0.kind, verdict: $1) }
        return UpdateRunReport.make(
            planned: planned,
            summary: UpdateRunSummary(items: outcomes, diagnostics: [], needsSudoPassword: false),
            finishedAt: Self.finishedAt, caskOperationID: Self.operationID,
            stillOutdatedKeys: [], confirmedKinds: [.formula, .cask, .appStore, .npm]
        )
    }

    private func undoable(_ token: String, operationID: UUID) -> UndoableUpdate {
        UndoableUpdate(operationID: operationID, token: token, appPath: "/Applications/\(token).app",
                       restoredVersion: "1", updatedAt: Self.finishedAt,
                       expiresAt: Self.finishedAt.addingTimeInterval(7 * 86_400))
    }

    private func store() -> ScanStore {
        makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }).store
    }

    @Test func aRowSpeaksOneSentence() throws {
        let entry = try #require(report([cask("slack")], [.executionFailed]).entries.first)
        let row = UpdateRunResultRow(entry: entry, undo: nil, isUndoing: false, onTrust: nil, onUndo: nil)
        withLanguage(.pl) {
            #expect(row.accessibilitySentence == "slack: nie udało się — szczegóły w logu")
            #expect(NSHostingView(rootView: row.frame(width: 420)).fittingSize.height > 0, "the row draws")
        }
        withLanguage(.en) {
            #expect(row.accessibilitySentence == "slack: failed — details in the log", "worded when read")
        }
        let list = try source(Self.summaryFile)
        #expect(list.contains("\"\\(entry.name): \\(note)\""))
        #expect(list.contains(".accessibilityElement(children: .combine)\n        .accessibilityLabel(accessibilitySentence)"),
                "one element per row; its buttons stay its actions")
    }

    @Test func rowsOfferOnlyTheActionsTheReportAllows() throws {
        let scan = store()
        var built = report([cask("proton-mail"), cask("slack"), cask("zoom")],
                           [.publisherChanged(old: "AAA", new: "BBB"), .succeeded, .succeeded])
        let slackUndo = undoable("slack", operationID: Self.operationID)
        scan.undoableUpdates = [slackUndo, undoable("zoom", operationID: UUID())]
        func row(_ name: String) throws -> UpdateRunResultRow {
            UpdateRunResultRow.make(entry: try #require(built.entries.first { $0.name == name }), in: built, scan: scan)
        }

        #expect(try row("proton-mail").onTrust != nil, "a changed publisher offers trust")
        #expect(try row("proton-mail").onUndo == nil)
        #expect(try row("slack").onUndo != nil, "this run's undo")
        #expect(try row("slack").undo == slackUndo, "and its note names that backup")
        #expect(try row("slack").onTrust == nil)
        #expect(try row("zoom").onUndo == nil, "another run's undo is not this row's")
        #expect(try row("slack").isUndoing == false)
        scan.undoBusy = "slack"
        #expect(try row("slack").isUndoing)
        #expect(try row("zoom").isUndoing == false)

        built.settlePublisher(token: "proton-mail")
        built.markUndone(token: "slack", restoredVersion: "1")
        #expect(try row("proton-mail").onTrust == nil, "a settled publisher offers nothing")
        #expect(try row("slack").onUndo == nil, "an undone row offers nothing")

        let list = try source(Self.summaryFile)
        #expect(list.contains("Task { await scan.trustNewPublisher(token: entry.name, reportedTeamID: entry.reportedTeamID, appURL: entry.appPath) }"))
        #expect(list.contains("Task { await scan.undoUpdate(undo) }"))
        #expect(list.contains("isUndoing: scan.undoBusy == entry.name"))
    }

    @Test func theSummaryListCannotQueueAnything() throws {
        let list = try source(Self.summaryFile)
        #expect(list.contains("ForEach(entries) { entry in"), "sanity: the rows are drawn here")
        for forbidden in ["SelectionCheckbox(", "QueueCircle(", ".contextMenu", "inspectedKey", "TapGesture", ".onTapGesture",
                          "Material", ".glassEffect(", ".system(size:", ".repeatForever("] {
            #expect(!list.contains(forbidden), "\(forbidden)")
        }
        let body = try slice(list, from: "struct UpdateRunSummaryList<HandOffs: View>: View", to: "private func group(")
        #expect(body.contains(".disabled(!ScanSelectionGate.allowsSelection(isRefreshing: scan.isRefreshing))"),
                "like listColumn's rows, the hand-offs are inert while the undo's check replaces them")
        #expect(list.contains(".disabled(scan.undoBusy != nil)"), "one undo at a time, as on the undo screen")
    }

    /// The groups in the spec's order, each in today's group-header style, then the restart bar
    /// and the log with `listColumn`'s own views and closures.
    @Test func theGroupsComeInOrderWithTheListsOwnTail() throws {
        let list = try source(Self.summaryFile)
        let body = try slice(list, from: "struct UpdateRunSummaryList<HandOffs: View>: View", to: "struct UpdateRunResultRow: View")
        let parts = [
            "group(.needsAttention, title: tr(\"Wymaga uwagi\"), tint: .wegaDanger, showsLogLink: true)",
            "group(.notStarted, title: tr(\"Nie zaczęłam\"), tint: .wegaToffee)",
            "\n                handOffs\n",
            "group(.updated, title: tr(\"Zaktualizowano\"), tint: .wegaSuccess)",
            "if !scan.restartCandidates.isEmpty {\n                    RestartSection(",
            "if scan.showLog {\n                    BrewLogPanel(lines: scan.brewLog, tapTrust: scan.tapTrustActions) { scan.showLog = false }",
        ]
        let positions = try parts.map { try #require(body.range(of: $0), "\($0)").lowerBound }
        #expect(positions == positions.sorted())
        #expect(body.contains("LazyVStack(spacing: WegaLayout.sectionSpacing)") && body.contains(".padding(WegaLayout.listGutter)"))
        #expect(body.contains("UpdateGroupHeader(title: title, tint: tint, count: entries.count)"))
        #expect(body.contains("Button(tr(\"Pokaż log\"), action: onShowLog)"))
        #expect(body.contains("if !entries.isEmpty {"), "a group shows only when it has rows")
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let column = try slice(view, from: "private var listColumn: some View", to: "/// F2 — \"show me exactly what you will do\"")
        let restart = try slice(body, from: "RestartSection(", to: "if scan.showLog {")
        for closure in ["onRestart: { info in Task { await scan.restartApp(info) } }", "onForce: { info in Task { await scan.confirmForceRestart(info) } }",
                        "onKeepOpen: { info in scan.keepAppOpen(info) }", "onDismissForcePrompt: { info in scan.dismissForceRestartPrompt(info) }"] {
            #expect(restart.contains(closure) && column.contains(closure), "\(closure)")
        }
        withLanguage(.en) {
            #expect(tr("Wymaga uwagi") == "Needs attention")
            #expect(tr("Nie zaczęłam") == "Not started")
            #expect(tr("Do dokończenia u producenta") == "To finish with the developer")
            #expect(tr("Zaktualizowano") == "Updated")
            #expect(trf("Pozostałe aktualizacje: %@ ›", "123") == "Remaining updates: 123 ›")
        }
    }

    @Test func theScreenShowsTheSummaryInsteadOfTheRows() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let screen = try slice(view, from: "private var screenBody: some View", to: "private var runListState:")
        let summary = try #require(screen.range(of: "if let report = scan.runReport {\n                UpdateRunSummaryList(report: report, onShowLog: { scan.showLog = true }, handOffs: {"))
        let rest = try #require(screen.range(of: """
            } else if scan.updating && !hasUpdates {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            listColumn
                                .frame(maxWidth: .infinity)
                                .disabled(!ScanSelectionGate.allowsSelection(isRefreshing: scan.isRefreshing))
                                .environment(\\.updateRun, runListState)
                        }
            """), "no hero and no empty category while a run empties the list; listColumn keeps its modifiers")
        for above in ["ScanBannerHost(onNavigate: onNavigate)", "RuleUndoToast(", "staleCaskCard", "PasswordPromptCallout(", "UpdatesSearchAnswerRow("] {
            let range = try #require(screen.range(of: above), "\(above)")
            #expect(range.upperBound < summary.lowerBound, "\(above) stays above all three")
        }
        #expect(summary.upperBound < rest.lowerBound)
        #expect(screen.components(separatedBy: "listColumn").count == 2, "one list, in the last branch")
    }

    /// "U producenta" in the band counts `handOffCount(for: .all)`; the group draws exactly those
    /// rows, with the urgency grouping's closures, so its actions work as they do there.
    @Test func theHandOffGroupDrawsWhatTheBandCounts() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("UpdateRunSummaryList(report: report, onShowLog: { scan.showLog = true }, handOffs: {\n                    UpdateRunHandOffGroup(onPinManual: requestPinManual)\n                })"))
        let group = try source("Sources/MacUpdater/UpdateRunHandOffGroup.swift")
        #expect(group.contains("items: scan.visibleManual, busyToken: scan.manualBusy,"))
        #expect(!group.contains("needsYou") && !group.contains("UrgencyGroups"), "every manual row, security-flagged ones included")
        #expect(group.contains("ForEach(scan.unresolvedDockerItems) { item in\n            UnresolvedDockerUpdateRow(item: item) { scan.inspectedKey = item.key }"))
        #expect(group.contains("ForEach(scan.unresolvedServiceItems) { item in\n            UnresolvedServiceUpdateRow(item: item) { scan.inspectedKey = item.key }"))
        #expect(group.contains("title: tr(\"Do dokończenia u producenta\"), tint: .wegaToffee,"))
        let urgency = try slice(view, from: "items: groups.needsYou, busyToken: scan.manualBusy,", to: "if updateFilter == .all || updateFilter == .apps {")
        for closure in ["onInstall: { token in Task { await scan.installManual(token: token) } },",
                        "inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreManual,",
                        "onSkip: scan.skipManual,", "onInspect: { scan.inspectedKey = \"m:\" + $0.path.path }"] {
            #expect(group.contains(closure) && urgency.contains(closure), "\(closure)")
        }
        #expect(group.contains("onPin: onPinManual,") && urgency.contains("onPin: requestPinManual,"))

        let scan = store()
        scan.manualOutdated = [ManualOutdatedApp(name: "Summary Probe", path: URL(fileURLWithPath: "/TestApplications/Summary Probe.app"),
                                                 installedVersion: "1", availableVersion: "2", source: .obsidian)]
        scan.brewOutdated = BrewOutdated(formulae: [], casks: [BrewOutdatedItem(name: "docker-desktop", installedVersions: ["1"], currentVersion: "2")])
        #expect(scan.visibleManual.count == 1 && scan.unresolvedDockerItems.count == 1, "sanity: both kinds of hand-off are present")
        #expect(scan.handOffCount(for: .all) == scan.visibleManual.count + scan.unresolvedDockerItems.count + scan.unresolvedServiceItems.count,
                "the band counts what the group draws")
    }

    @Test func theSummaryHeaderReplacesTheListHeaderInResultsView() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let results = try slice(view, from: "private var resultsView: some View", to: "private var listHeader: some View")
        #expect(results.contains("""
                            if scan.runReport != nil {
                                UpdateRunSummaryHeader(remainingCount: scan.scopeCounts.all, onClose: { scan.closeRunReport() })
                            } else {
                                listHeader
                            }
            """))
        let header = try slice(view, from: "private var listHeader: some View", to: "private var resultsBand: some View")
        #expect(!header.contains("runReport"), "listHeader's own body is not wrapped")
        let list = try source(Self.summaryFile)
        let summaryHeader = try slice(list, from: "struct UpdateRunSummaryHeader: View", to: "struct UpdateRunSummaryList<HandOffs: View>")
        for part in ["QueueColumnPlaceholder()", "Text(tr(\"Wynik aktualizacji\"))", ".textCase(.uppercase)", "Spacer(minLength: 0)",
                     "if remainingCount > 0 {", "Button(trf(\"Pozostałe aktualizacje: %@ ›\", \"\\(remainingCount)\"), action: onClose)",
                     ".buttonStyle(.link)"] {
            #expect(summaryHeader.contains(part), "\(part)")
        }
    }

    /// Review Focus 5 — the rows are not on screen, so ⇧⌘A has nothing to select; and a run
    /// stopped at the zeroth boundary keeps its selection, so ⌘⏎ would start rows the summary hides.
    @Test func selectAllAndUpdateAreOffWhileTheSummaryIsOpen() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let selectAll = try #require(view.range(of: ".focusedSceneValue(\\.selectAllVisibleAction")).upperBound
        #expect(view[selectAll...].prefix(300).contains(
            "ScanSelectionGate.allowsListSelection(isRefreshing: scan.isRefreshing, isUpdating: scan.updating) && scan.runReport == nil"))
        let run = try #require(view.range(of: ".focusedSceneValue(\\.runUpdateAction")).upperBound
        #expect(view[run...].prefix(200).contains("isEnabled: scan.status == .results && allowsUpdateRun && scan.runReport == nil,"))
    }

    // MARK: - Helpers

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ text: String, from: String, to: String) throws -> String {
        let start = try #require(text.range(of: from))
        let region = text[start.lowerBound...]
        let end = try #require(region.range(of: to, range: start.upperBound..<region.endIndex))
        return String(region[..<end.lowerBound])
    }
}

/// The summary header takes the list header's row: no taller than the row with the scope bar
/// and the grouping menu, its title and link on one line at the minimum detail column.
@MainActor
final class UpdateRunSummaryHeaderLayoutTests: XCTestCase {
    /// The header's width at the 420 pt minimum detail column (as `ListHeaderScanNoteLayoutTests`).
    private static let width: CGFloat = 420 - 2 * WegaLayout.selectionColumnInset

    func testTheSummaryHeaderKeepsTheHeaderHeight() {
        for language in [AppLanguage.pl, .en] {
            withLanguage(language) {
                let scopeRow = fitting(HStack(spacing: WegaLayout.checkboxSpacing) {
                    SelectionCheckbox(state: .none, accessibilityLabel: "x", toggle: {})
                    UpdateScopeBar(filter: .all, counts: UpdateScopeCounts(apps: 128, cli: 46, security: 12)) { _ in }
                    Spacer(minLength: 0)
                    ListHeaderGroupingSlot(showsScanNote: false, showsRunNote: false) {
                        UpdateGroupingMenu(selection: .constant(.default))
                    }
                })
                let summary = fitting(UpdateRunSummaryHeader(remainingCount: 123, onClose: {}))
                let title = NSHostingView(rootView: Text(tr("Wynik aktualizacji"))
                    .font(.wega(.subheadline, weight: .semibold, monospaced: true)).fixedSize()).fittingSize
                let ideal = NSHostingView(rootView: UpdateRunSummaryHeader(remainingCount: 123, onClose: {}).fixedSize()).fittingSize
                let closed = NSHostingView(rootView: UpdateRunSummaryHeader(remainingCount: 0, onClose: {}).fixedSize()).fittingSize
                let context = "\(language)"
                XCTAssertLessThanOrEqual(summary.height, scopeRow.height + 0.5, "\(context): the summary header is taller than the list header")
                XCTAssertGreaterThanOrEqual(summary.height, title.height - 0.5, "\(context): the header shows its title")
                XCTAssertLessThanOrEqual(ideal.width, Self.width + 0.5, "\(context): the title and the link do not fit one line")
                XCTAssertLessThan(closed.width, ideal.width, "\(context): no link without remaining updates")
            }
        }
    }

    private func fitting(_ view: some View) -> CGSize {
        NSHostingView(rootView: view.frame(width: Self.width, alignment: .leading)).fittingSize
    }
}
