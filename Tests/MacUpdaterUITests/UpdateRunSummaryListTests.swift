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
            stillOutdatedKeys: [], confirmed: true
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
        #expect(list.contains("\"\\(displayName): \\(note)\""))
        #expect(list.contains("""
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessibilitySentence)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityActions {
                        if isEnabled {
                            if let onTrust { Button(tr("Zaufaj nowemu podpisowi"), action: onTrust) }
                            if let onUndo, !isUndoing { Button(tr("Cofnij"), action: onUndo) }
                            if let onOpenTouchIDCard { Button(tr("Otwórz kartę Touch ID"), action: onOpenTouchIDCard) }
                        }
                    }
            """), "one element per row, as the list's rows: its buttons are also its named actions")
        // R-I2 — `.disabled` alone leaves VoiceOver's actions reachable. The row is disabled while
        // any undo runs and the list while the undo's check runs, so its actions follow the
        // environment's `isEnabled`, as `PackageRow`'s do.
        let rowSource = try slice(list, from: "struct UpdateRunResultRow: View", to: "private var icon: some View")
        #expect(rowSource.contains("@Environment(\\.isEnabled) private var isEnabled"))
        #expect(rowSource.components(separatedBy: ".accessibilityActions {").count == 2, "one actions block, the gated one")
    }

    /// Final review C12 — while its undo restores the app, the row says so to VoiceOver, where the
    /// sighted user sees the spinner that replaced „Cofnij”.
    @Test func aRowSaysItsUndoIsRunning() throws {
        let entry = try #require(report([cask("slack")], [.succeeded]).entries.first)
        let undo = undoable("slack", operationID: Self.operationID)
        let undoing = UpdateRunResultRow(entry: entry, undo: undo, isUndoing: true, onTrust: nil, onUndo: {})
        let idle = UpdateRunResultRow(entry: entry, undo: undo, isUndoing: false, onTrust: nil, onUndo: {})
        withLanguage(.pl) {
            #expect(undoing.accessibilityValue == "cofam…")
            #expect(idle.accessibilityValue.isEmpty)
        }
        withLanguage(.en) {
            #expect(undoing.accessibilityValue == "undoing…", "worded when read")
        }
    }

    /// Final review C10 — a cask row names the app as every other list in the app does, with the
    /// token under it; the note still drops the "{token}: " its sentence starts with.
    @Test func aCaskRowNamesTheAppAndItsToken() throws {
        let planned = [cask("proton-mail"), OutdatedItem(key: UpdatePlanner.key(name: "wget", kind: .formula), name: "wget",
                                                         from: "1", to: "2", kind: .formula)]
        let outcomes = [ItemUpdateOutcome(key: planned[0].key, name: "proton-mail", kind: .cask, verdict: .publisherChanged(old: "AAA", new: "BBB")),
                        ItemUpdateOutcome(key: planned[1].key, name: "wget", kind: .formula, verdict: .executionFailed)]
        let built = UpdateRunReport.make(
            planned: planned, summary: UpdateRunSummary(items: outcomes, diagnostics: [], needsSudoPassword: false),
            finishedAt: Self.finishedAt, caskAppPaths: ["proton-mail": URL(fileURLWithPath: "/Applications/Proton Mail.app")],
            stillOutdatedKeys: [], confirmed: true
        )
        let app = UpdateRunResultRow(entry: built.entries[0], undo: nil, isUndoing: false, onTrust: nil, onUndo: nil)
        let tool = UpdateRunResultRow(entry: built.entries[1], undo: nil, isUndoing: false, onTrust: nil, onUndo: nil)
        try withLanguage(.pl) {
            #expect(app.displayName == "Proton Mail")
            #expect(app.displayName == CaskDisplayName.name(token: "proton-mail", appPath: built.entries[0].appPath))
            #expect(app.shownToken == "proton-mail")
            #expect(!app.note.hasPrefix("proton-mail: "), "\(app.note)")
            #expect(app.accessibilitySentence == "Proton Mail: \(app.note)")
            #expect(tool.displayName == "wget" && tool.shownToken == nil, "a formula is named by its token alone")
            let unnamed = try #require(report([cask("zoom")], [.succeeded]).entries.first)
            let bare = UpdateRunResultRow(entry: unnamed, undo: nil, isUndoing: false, onTrust: nil, onUndo: nil)
            #expect(bare.displayName == "zoom" && bare.shownToken == nil, "no bundle, no second line")
        }
        let list = try source(Self.summaryFile)
        let row = try slice(list, from: "struct UpdateRunResultRow: View", to: "private var icon: some View")
        #expect(row.contains("Text(displayName).font(.wega(.body, weight: .semibold))"))
        #expect(row.contains("if let shownToken {\n                    Text(shownToken)\n                        .font(.wega(.caption, monospaced: true))"))
    }

    @Test func rowsOfferOnlyTheActionsTheReportAllows() throws {
        let scan = store()
        var built = report([cask("proton-mail"), cask("slack"), cask("zoom")],
                           [.publisherChanged(old: "AAA", new: "BBB"), .succeeded, .succeeded])
        let slackUndo = undoable("slack", operationID: Self.operationID)
        scan.undoableUpdates = [slackUndo, undoable("zoom", operationID: UUID())]
        func row(_ name: String) throws -> UpdateRunResultRow {
            UpdateRunResultRow.make(entry: try #require(built.entries.first { $0.name == name }), in: built, scan: scan,
                                    requestUndo: { _ in })
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
        #expect(list.contains("isUndoing: scan.undoBusy == entry.name"))
    }

    /// "Cofnij" in the summary asks the undo screen's own question — the app, the pin, until when
    /// the copy is kept and, for Docker, what the copy does not hold — and only its answer undoes.
    @Test func theSummarysUndoAsksTheUndoScreensQuestion() throws {
        let scan = store()
        let built = report([cask("slack")], [.succeeded])
        let slackUndo = undoable("slack", operationID: Self.operationID)
        scan.undoableUpdates = [slackUndo]
        var requested: UndoableUpdate?
        let row = UpdateRunResultRow.make(entry: try #require(built.entries.first), in: built, scan: scan,
                                          requestUndo: { requested = $0 })
        let undo = try #require(row.onUndo)
        undo()
        #expect(requested == slackUndo, "the button asks for the confirmation of this run's undo")
        #expect(scan.undoBusy == nil, "and starts nothing itself")

        let list = try source(Self.summaryFile)
        #expect(!list.contains("undoUpdate("), "the summary never undoes on its own")
        #expect(list.contains("requestUndo: { undo in\n                        undoTarget = undo\n                        showUndoConfirmation = true\n                    }"))
        #expect(list.contains(".undoConfirmation(target: $undoTarget, isPresented: $showUndoConfirmation)"))
        #expect(list.contains(".wegaAttention(showUndoConfirmation)"), "the open question holds Wega's ball")
        let rollback = try source("Sources/MacUpdater/RollbackView.swift")
        #expect(rollback.contains(".undoConfirmation(target: $undoTarget, isPresented: $showUndoConfirmation)"), "one copy for both screens")
        #expect(!rollback.contains(".confirmationDialog(") && !rollback.contains("undoUpdate("))
        let confirmation = try source("Sources/MacUpdater/UndoConfirmation.swift")
        #expect(confirmation.components(separatedBy: "scan.undoUpdate(").count == 2, "one call, behind „Przywróć wersję”")
        let restore = try slice(confirmation, from: "Button(trf(\"Przywróć wersję %@\"", to: "Button(tr(\"Anuluj\"), role: .cancel)")
        #expect(restore.contains("Task { await scan.undoUpdate(target) }"))

        let docker = UndoableUpdate(operationID: Self.operationID, token: "docker-desktop", appPath: "/Applications/Docker.app",
                                    restoredVersion: "4.40", updatedAt: Self.finishedAt,
                                    expiresAt: Self.finishedAt.addingTimeInterval(7 * 86_400))
        let notice = try #require(RollbackScopePresentation.notice(for: docker.rollbackScope))
        withLanguage(.pl) {
            let restoration = trf("%@ zostanie zastąpiona kopią sprzed aktualizacji, a przywrócona wersja zostanie przypięta. Kopia jest trzymana do %@.",
                                  "docker-desktop", docker.expiresAt.formatted(date: .abbreviated, time: .omitted))
            #expect(UndoConfirmation.message(for: docker) == "\(restoration)\n\n\(notice.localizedDescription)")
            #expect(UndoConfirmation.message(for: slackUndo) == trf(
                "%@ zostanie zastąpiona kopią sprzed aktualizacji, a przywrócona wersja zostanie przypięta. Kopia jest trzymana do %@.",
                "slack", slackUndo.expiresAt.formatted(date: .abbreviated, time: .omitted)))
        }
    }

    /// Docker's copy holds only Docker.app; the row says so where it offers "Cofnij".
    @Test func aDockerUndoRowCarriesTheScopeNotice() throws {
        let entry = try #require(report([cask("docker-desktop")], [.succeeded]).entries.first)
        func height(undoToken: String) -> CGFloat {
            let undo = undoable(undoToken, operationID: Self.operationID)
            let row = UpdateRunResultRow(entry: entry, undo: undo, isUndoing: false, onTrust: nil, onUndo: {})
            return withLanguage(.pl) { NSHostingView(rootView: row.frame(width: 420)).fittingSize.height }
        }
        #expect(RollbackProtection.scope(token: "docker-desktop") == .dockerAppBundleOnly)
        #expect(RollbackProtection.scope(token: "docker-desktop-probe") == .appBundleOnly)
        #expect(height(undoToken: "docker-desktop") > height(undoToken: "docker-desktop-probe"), "the notice is drawn")
        let list = try source(Self.summaryFile)
        let row = try slice(list, from: "struct UpdateRunResultRow: View", to: "private var icon: some View")
        #expect(row.contains("if let undo {\n                    RollbackScopeNotice(scope: undo.rollbackScope, compact: true)\n                }"))
    }

    /// Spec ruling — the row names the item, so a note that begins with "{name}: " (a changed
    /// publisher, a failed rollback) drops it; the banners raised on close keep the whole sentence.
    @Test func aRowNamesItsItemOnce() throws {
        let scan = store()
        let built = report([cask("proton-mail"), cask("zoom")],
                           [.publisherChanged(old: "AAA", new: "BBB"), .rollbackFailed])
        for language in [AppLanguage.pl, .en] {
            try withLanguage(language) {
                for entry in built.entries {
                    let row = UpdateRunResultRow(entry: entry, undo: nil, isUndoing: false, onTrust: nil, onUndo: nil)
                    #expect(entry.note(undo: nil).hasPrefix("\(entry.name): "), "sanity: the report's sentence names it")
                    #expect(!row.note.contains(entry.name), "\(language): \(row.note)")
                    #expect(row.accessibilitySentence.components(separatedBy: entry.name).count == 2, "\(language): \(row.accessibilitySentence)")
                    #expect(row.accessibilitySentence == "\(entry.name): \(row.note)")
                }
                let changed = try #require(built.entries.first)
                scan.setRunReport(built)
                scan.closeRunReport()
                let banner = try #require(scan.banner)
                #expect(banner.title == tr("Zmienił się podpis producenta"))
                #expect(banner.message == changed.note(undo: nil), "\(language): the banner keeps the whole sentence")
                #expect(banner.message.contains("proton-mail"))
                while scan.banner != nil { scan.dismissBanner() }
            }
        }
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
            // Final review C17 — „nie uruchomiłam — szczegóły w logu” points at the log, so this
            // group offers the link too.
            "group(.notStarted, title: tr(\"Nie zaczęłam\"), tint: .wegaToffee, showsLogLink: true)",
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

    @Test func aFinishedRunLeavesRemainingUpdatesVisibleAndItsDetailsCollapsed() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("@State private var showsRunSummary = false"))

        let results = try slice(view, from: "private var resultsView: some View", to: "private var listHeader: some View")
        let pendingHeader = try #require(results.range(of: "listHeader"))
        let recap = try #require(results.range(of: "UpdateRunRecap("))
        #expect(pendingHeader.lowerBound < recap.lowerBound)
        #expect(results.contains("if let report = scan.runReport, displayedReport == nil"))

        let reportView = try slice(view, from: "private var screenBody: some View", to: "private var runListState:")
        #expect(reportView.contains("if let report = displayedReport"))
        #expect(reportView.contains("listColumn"))
        #expect(view.contains(".onChange(of: scan.runReport?.finishedAt)"))
        #expect(view.contains("if onScreen, finishedAt != nil, scan.scopeCounts.all > 0, !scopeHasUpdates"))
        #expect(view.contains("wegaLine:       scan.runReport == nil ? wegaLine : \"\""))
        #expect(view.contains("summary: displayedReport.map(summaryPresentation)"))
    }

    @Test func explicitlyExpandingTheReportShowsItsDetailedRows() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let screen = try slice(view, from: "private var screenBody: some View", to: "private var runListState:")
        let summary = try #require(screen.range(of: "if let report = displayedReport {\n                UpdateRunSummaryList(report: report, onShowLog: { scan.showLog = true }, handOffs: {"))
        let rest = try #require(screen.range(of: """
            } else if scan.updating && !showsRows {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            listColumn
                                .frame(maxWidth: .infinity)
                                .overlay { if ScanSelectionGate.coversList(isRefreshing: scan.isRefreshing, showsRows: showsRows) { ScanListVeil() } }
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

    /// Spec §4 names both empty states. "Nic w tej kategorii" shows when the category on screen is
    /// empty while another still has rows — so the blank area asks `showsRows`, the list's own
    /// answer, which a restart-only list keeps true.
    @Test func theBlankAreaAlsoCoversAnEmptiedCategory() throws {
        let cask = cask("slack")
        let formula = OutdatedItem(key: UpdatePlanner.key(name: "wget", kind: .formula), name: "wget", from: "1", to: "2", kind: .formula)
        let none: (ManualOutdatedApp) -> Bool = { _ in false }
        #expect(UpdateView.filterHasContent(.all, items: [cask], manual: [], isSecurity: none), "there are updates")
        #expect(!UpdateView.filterHasContent(.cli, items: [cask], manual: [], isSecurity: none),
                "the CLI rows were all updated: the category on screen is empty")
        #expect(UpdateView.filterHasContent(.cli, items: [formula], manual: [], isSecurity: none))
        #expect(UpdateView.filterHasContent(.apps, items: [cask], manual: [], isSecurity: none))
        #expect(!UpdateView.filterHasContent(.security, items: [cask], manual: [], isSecurity: none))

        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("""
                private var scopeHasUpdates: Bool {
                    Self.filterHasContent(updateFilter, items: allItems, manual: visibleManual, isSecurity: scan.isSecurityApp)
                }

                private var showsRows: Bool { scopeHasUpdates || !scan.restartCandidates.isEmpty }
            """), "the same answer listColumn reads; restarts alone keep the list")
        let column = try slice(view, from: "private var listColumn: some View", to: "/// F2 — \"show me exactly what you will do\"")
        #expect(column.contains("} else if showsRows {"), "listColumn's empty category is exactly !showsRows")
        #expect(!view.contains("private func filterHasContent("), "one rule, the static one")
    }

    /// "U producenta" in the band counts `handOffCount(for: .all)`; the group draws exactly those
    /// rows, with the urgency grouping's closures, so its actions work as they do there.
    @Test func theHandOffGroupDrawsWhatTheBandCounts() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("UpdateRunSummaryList(report: report, onShowLog: { scan.showLog = true }, handOffs: {\n                    UpdateRunHandOffGroup(onPinManual: requestPinManual)\n                })"))
        let group = try source("Sources/MacUpdater/UpdateRunHandOffGroup.swift")
        #expect(group.contains("items: scan.externalManualUpdates, busyToken: scan.manualBusy,"))
        #expect(!group.contains("needsYou") && !group.contains("UrgencyGroups"), "all hand-offs, including security updates")
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
        let vendor = ManualOutdatedApp(name: "Summary Probe", path: URL(fileURLWithPath: "/TestApplications/Summary Probe.app"),
                                        installedVersion: "1", availableVersion: "2", source: .obsidian)
        let replacement = ManualOutdatedApp(
            name: "Queued Probe", path: URL(fileURLWithPath: "/Applications/Queued Probe.app"),
            installedVersion: "1", availableVersion: "2", source: .cask(token: "queued-probe"),
            bundleIdentifier: "com.example.queued-probe"
        )
        scan.manualOutdated = [vendor, replacement]
        scan.caskProfiles["queued-probe"] = CaskArtifactProfile(token: "queued-probe", homepage: nil, artifacts: [
            CaskArtifact(kind: .app, names: ["Queued Probe.app"])
        ])
        scan.brewOutdated = BrewOutdated(formulae: [], casks: [BrewOutdatedItem(name: "docker-desktop", installedVersions: ["1"], currentVersion: "2")])
        #expect(scan.visibleManual.count == 2 && scan.unresolvedDockerItems.count == 1)
        #expect(scan.queueableCaskReplacements(for: .all).map(\.app) == [replacement])
        #expect(scan.externalManualUpdates == [vendor])
        #expect(scan.handOffCount(for: .all) == scan.externalManualUpdates.count + scan.unresolvedDockerItems.count + scan.unresolvedServiceItems.count,
                "the band counts what the group draws")
    }

    @Test func theSummaryHeaderOnlyReplacesTheListHeaderWhenExpanded() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let results = try slice(view, from: "private var resultsView: some View", to: "private var listHeader: some View")
        #expect(results.contains("""
                            if displayedReport != nil {
                                UpdateRunSummaryHeader(remainingCount: scan.scopeCounts.all, categoryHasRows: scopeHasUpdates,
                                                       onClose: { showsRunSummary = false }, onShowAll: { onScopeChange?(.all) })
                            } else {
                                listHeader
                            }
            """), "the category on screen has rows exactly when listColumn would not draw „Nic w tej kategorii”")
        let header = try slice(view, from: "private var listHeader: some View", to: "private var resultsBand: some View")
        #expect(!header.contains("runReport"), "listHeader's own body is not wrapped")
        let list = try source(Self.summaryFile)
        let summaryHeader = try slice(list, from: "struct UpdateRunSummaryHeader: View", to: "struct UpdateRunSummaryList<HandOffs: View>")
        for part in ["QueueColumnPlaceholder()", "Text(tr(\"Wynik aktualizacji\"))", ".textCase(.uppercase)", "Spacer(minLength: 0)",
                     "if remainingCount > 0 {", "Button(trf(\"Pozostałe aktualizacje: %@ ›\", \"\\(remainingCount)\"), action: close)",
                     ".buttonStyle(.link)"] {
            #expect(summaryHeader.contains(part), "\(part)")
        }
    }

    /// Final review C15 — „Pozostałe aktualizacje: N ›” counts every category, so it never lands on
    /// „Nic w tej kategorii”: when the category on screen has no rows left, closing also brings
    /// back „Wszystkie”. The band's „Zamknij podsumowanie” promises nothing and keeps the category.
    @Test func theRemainingLinkNeverLandsOnAnEmptyCategory() {
        final class Calls { var made: [String] = [] }
        for hasRows in [false, true] {
            let calls = Calls()
            let header = UpdateRunSummaryHeader(remainingCount: 3, categoryHasRows: hasRows,
                                                onClose: { calls.made.append("close") }, onShowAll: { calls.made.append("all") })
            header.close()
            #expect(calls.made == (hasRows ? ["close"] : ["close", "all"]), "rows on screen: \(hasRows)")
        }
    }

    /// Review Focus 5 — the rows are not on screen, so ⇧⌘A has nothing to select; and a run
    /// stopped at the zeroth boundary keeps its selection, so ⌘⏎ would start rows the summary hides.
    @Test func selectAllAndUpdateAreOffWhileTheSummaryIsExpanded() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let selectAll = try #require(view.range(of: ".focusedSceneValue(\\.selectAllVisibleAction")).upperBound
        #expect(view[selectAll...].prefix(300).contains(
            "ScanSelectionGate.allowsListSelection(isRefreshing: scan.isRefreshing, isUpdating: scan.updating) && displayedReport == nil"))
        let run = try #require(view.range(of: ".focusedSceneValue(\\.runUpdateAction")).upperBound
        #expect(view[run...].prefix(200).contains("isEnabled: scan.status == .results && allowsUpdateRun && displayedReport == nil,"))
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

/// The summary header takes the list header's row: exactly the height of the row with the scope
/// bar and the grouping menu, so the list does not move when the summary opens or closes, and
/// its title and link on one line at the minimum detail column.
@MainActor
final class UpdateRunSummaryHeaderLayoutTests: XCTestCase {
    /// The header's width at the 420 pt minimum detail column (as `ListHeaderScanNoteLayoutTests`).
    private static let width: CGFloat = 420 - 2 * WegaLayout.selectionColumnInset

    private func header(remaining: Int) -> UpdateRunSummaryHeader {
        UpdateRunSummaryHeader(remainingCount: remaining, categoryHasRows: true, onClose: {}, onShowAll: {})
    }

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
                let summary = fitting(header(remaining: 123))
                let withoutLink = fitting(header(remaining: 0))
                let title = NSHostingView(rootView: Text(tr("Wynik aktualizacji"))
                    .font(.wega(.subheadline, weight: .semibold, monospaced: true)).fixedSize()).fittingSize
                let ideal = NSHostingView(rootView: header(remaining: 123).fixedSize()).fittingSize
                let closed = NSHostingView(rootView: header(remaining: 0).fixedSize()).fittingSize
                let context = "\(language)"
                XCTAssertEqual(summary.height, scopeRow.height, accuracy: 0.5,
                               "\(context): the summary header is \(summary.height) pt, the list header \(scopeRow.height) pt")
                XCTAssertEqual(withoutLink.height, scopeRow.height, accuracy: 0.5,
                               "\(context): without the link the summary header is \(withoutLink.height) pt, the list header \(scopeRow.height) pt")
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
