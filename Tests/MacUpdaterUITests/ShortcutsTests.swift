import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-23 — ⌘F always went to the inventory, though Logs and Uninstall have a search field of
/// their own; ⌘. only stopped an update; and there was no ⇧⌘A, no ⌥⌘I and no Help.
@Suite("Shortcuts") @MainActor
struct ShortcutsTests {
    private enum StubError: Error {
        case unexpected([String])
    }

    @Test func findWorksOnTheScreenThatHasAField() {
        let tabs: [SidebarTab] = [.update, .rollback, .uninstall, .cleanup, .migration, .inventory, .logs]
        #expect(Set(tabs.filter(\.hasSearchField)) == [.update, .logs, .uninstall, .inventory])
        let center = WegaCommandCenter()
        center.requestSearchFocus(on: .logs)
        #expect(!center.consumePendingSearchFocus(on: .uninstall))
        #expect(center.consumePendingSearchFocus(on: .logs) && !center.consumePendingSearchFocus(on: .logs))
        withLanguage(.en) {
            #expect(tr("Znajdź na tym ekranie") == "Find on This Screen" && tr("Zaznacz wszystkie widoczne") == "Select All Visible")
            #expect(tr("Pokaż panel szczegółów") == "Show Inspector" && tr("Przewodnik po Wedze") == "Wega User Guide")
            #expect(CancelCommandCopy.title(run: .idle) == "Cancel Scan")
        }
        #expect(CancelCommandCopy.title(run: .running) == UpdateRunCopy.stopLabel(isStopping: false))
    }

    /// While a run stops, ⌘. is disabled but still names the run, in the words its own button
    /// uses then; it never turns into „Anuluj skan” mid-run.
    @Test func cancelNamesTheRunWhileItStops() {
        #expect(UpdateRunCommandState(isUpdating: false, isStopping: false) == .idle)
        #expect(UpdateRunCommandState(isUpdating: true, isStopping: false) == .running)
        #expect(UpdateRunCommandState(isUpdating: true, isStopping: true) == .stopping)
        #expect(UpdateRunCommandState(isUpdating: false, isStopping: true) == .idle, "a stop left over from a finished run")
        #expect(CancelCommandCopy.title(run: .stopping) == UpdateRunCopy.stopLabel(isStopping: true))
        #expect(CancelCommandCopy.title(run: .running) != CancelCommandCopy.title(run: .stopping))
        withLanguage(.en) {
            #expect(CancelCommandCopy.title(run: .stopping) != "Cancel Scan")
        }
    }

    /// ⌘. cancels the scan the screen shows, from published state like the toolbar's „Anuluj”:
    /// a scan that takes the window or one that refreshes under the list, never the check that
    /// belongs to a run or an undo. With no run and no undo, exactly one of ⌘R and ⌘. is offered.
    @Test func cancelFollowsTheScanOnScreenAndNeverTheRun() throws {
        let (store, _) = try storeWithFormulaAndCask()
        #expect(!store.canCancelScan, "nothing is scanning")
        store.status = .checking
        #expect(store.canCancelScan, "a scan holds the window")
        store.status = .results
        store.setRefreshing(true)
        #expect(store.canCancelScan, "a refresh runs under the list")
        store.setRefreshing(false)
        for status in [UpdateStatus.ready, .checking, .results] {
            for refreshing in [false, true] {
                for updating in [false, true] {
                    store.status = status
                    store.setRefreshing(refreshing)
                    store.updating = updating
                    let state = "\(status), refreshing \(refreshing), updating \(updating)"
                    #expect(!(store.canCancelScan && updating), "⌘. stops the run instead: \(state)")
                    if !updating { #expect(store.canCancelScan != store.canStartCheck, "\(state)") }
                }
            }
        }
    }

    /// C2 stage 4 — the undo's check runs outside `scanTask`, like the run's, so `cancelScan()`
    /// cannot stop it: neither ⌘. nor „Anuluj” offers to, and no second scan starts under it.
    @Test func nothingCancelsOrRestartsTheUndosCheck() throws {
        let (store, _) = try storeWithFormulaAndCask()
        store.undoBusy = "slack"
        store.setRefreshing(true)
        #expect(!store.canCancelScan, "the undo's check cannot be cancelled")
        #expect(!store.canStartCheck, "no second scan under the undo's check")
        store.undoBusy = nil
        #expect(store.canCancelScan && !store.canStartCheck, "a refresh of its own is cancellable again")
    }

    /// ⌘. is one item for two stops: the running update when there is one to stop, the scan
    /// otherwise, nothing when neither runs.
    @Test func cancelStopsTheUpdateFirstAndTheScanOtherwise() {
        var ran: [String] = []
        let stop = { (enabled: Bool) in WegaMenuAction(isEnabled: enabled, run: { ran.append("update") }) }
        let cancel = { (enabled: Bool) in WegaMenuAction(isEnabled: enabled, run: { ran.append("scan") }) }

        WegaMenuAction.firstEnabled(stop(false), cancel(true))?.run()
        #expect(ran == ["scan"], "no update runs, so ⌘. cancels the scan")
        WegaMenuAction.firstEnabled(stop(true), cancel(false))?.run()
        #expect(ran == ["scan", "update"])
        #expect(WegaMenuAction.firstEnabled(stop(false), cancel(false)) == nil, "nothing to stop, the item is disabled")
        #expect(WegaMenuAction.firstEnabled(nil, nil) == nil)
    }

    @Test func selectAllVisibleNeverReachesWhatTheUserCannotSee() throws {
        let (store, items) = try storeWithFormulaAndCask()
        store.selectAllVisible(filter: .cli)
        #expect(store.selected == [items.formula.key], "the cask is filtered out")
        store.selectAllVisible(filter: .all)
        #expect(store.selected == Set([items.formula.key, items.cask.key]))
        store.selectAllVisible(filter: .cli)
        #expect(store.selected == [items.formula.key], "the queued cask leaves with the filter that hides it")
    }

    /// A row a rule hides and a manually updated app are never batch rows, so ⇧⌘A queues neither.
    @Test func selectAllVisibleSkipsHiddenAndManualRows() throws {
        let (store, items) = try storeWithFormulaAndCask()
        let hidden = "shortcuts-hidden-\(UUID().uuidString)"
        store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: items.formula.name, installedVersions: ["1"], currentVersion: "2"),
                       BrewOutdatedItem(name: hidden, installedVersions: ["1"], currentVersion: "2")],
            casks: [BrewOutdatedItem(name: items.cask.name, installedVersions: ["1"], currentVersion: "2")]
        )
        let hiddenItem = try #require(store.allItems.first { $0.name == hidden })
        UpdatePolicyStore.shared.ignore(key: hiddenItem.policyKey, name: hidden)
        defer { UpdatePolicyStore.shared.remove(key: hiddenItem.policyKey) }
        let app = ManualOutdatedApp(
            name: "Shortcuts Manual",
            path: URL(fileURLWithPath: "/Applications/Shortcuts-\(UUID().uuidString).app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle,
            bundleIdentifier: "example.shortcuts.\(UUID().uuidString)"
        )
        store.manualOutdated = [app]

        store.selectAllVisible(filter: .all)
        #expect(store.selected == Set([items.formula.key, items.cask.key]))
    }

    /// The list is not the one on screen while it refreshes, belongs to the run while it updates,
    /// and is not drawn at all while a full scan holds the window.
    @Test func selectAllVisibleWaitsForTheListOnScreen() throws {
        let (store, items) = try storeWithFormulaAndCask()
        store.updating = true
        store.selectAllVisible(filter: .all)
        #expect(store.selected.isEmpty, "a running update owns the selection")
        store.updating = false
        store.selected = []
        store.setRefreshing(true)
        store.selectAllVisible(filter: .all)
        #expect(store.selected.isEmpty, "a refresh is replacing the list")
        store.setRefreshing(false)
        store.selected = []
        store.status = .checking
        store.selectAllVisible(filter: .all)
        #expect(store.selected.isEmpty, "no rows are drawn")
        store.status = .results
        store.selectAllVisible(filter: .all)
        #expect(store.selected == Set([items.formula.key, items.cask.key]), "the list on screen takes it")
    }

    @Test func theMenuCarriesTheShortcuts() throws {
        let commands = try source("Sources/MacUpdater/WegaCommands.swift")
        for literal in [".keyboardShortcut(\"f\", modifiers: .command)", ".keyboardShortcut(\"f\", modifiers: [.command, .shift])",
                        ".keyboardShortcut(\"a\", modifiers: [.command, .shift])", ".keyboardShortcut(\"i\", modifiers: [.command, .option])",
                        ".keyboardShortcut(\".\", modifiers: .command)", "CommandGroup(replacing: .help)", "AppEndpoints.shared.userGuideURL"] {
            #expect(commands.contains(literal), "\(literal)")
        }
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains(".focusedSceneValue(\\.cancelScanAction") && view.contains(".focusedSceneValue(\\.selectAllVisibleAction"))
        #expect(try source("Sources/MacUpdater/ContentView.swift").contains(".focusedSceneValue(\\.toggleInspectorAction"))
        for file in ["LogsView", "UninstallView", "InventoryView"] {
            #expect(try source("Sources/MacUpdater/\(file).swift").contains(".searchFocused($searchFocused)"), "\(file)")
        }
    }

    /// The menu asks the same gates the screen does: ⌘F only where a field is, ⇧⌘A only on
    /// Updates, the select-all action from the list's own gate.
    @Test func theNewCommandsShareTheScreensGates() throws {
        let commands = try source("Sources/MacUpdater/WegaCommands.swift")
        #expect(commands.contains(".disabled(!selection.tab.hasSearchField)"))
        #expect(commands.contains(".disabled(!(selection.tab == .update && selectAllVisible?.isEnabled == true))"))
        #expect(commands.contains(".disabled(cancelTarget == nil)"))
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let action = try #require(view.range(of: ".focusedSceneValue(\\.selectAllVisibleAction")).upperBound
        #expect(view[action...].prefix(300).contains("ScanSelectionGate.allowsListSelection(isRefreshing: scan.isRefreshing, isUpdating: scan.updating)"))
        for file in ["LogsView": ".logs", "UninstallView": ".uninstall", "InventoryView": ".inventory"] {
            #expect(try source("Sources/MacUpdater/\(file.key).swift").contains(".receivesSearchFocusRequests(on: \(file.value))"), "\(file.key)")
        }
    }

    // MARK: - Helpers

    private func storeWithFormulaAndCask() throws -> (ScanStore, (formula: OutdatedItem, cask: OutdatedItem)) {
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        let formula = "shortcuts-formula-\(UUID().uuidString)"
        let cask = "shortcuts-cask-\(UUID().uuidString)"
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")],
            casks: [BrewOutdatedItem(name: cask, installedVersions: ["1"], currentVersion: "2")]
        )
        harness.store.status = .results
        let formulaItem = try #require(harness.store.allItems.first { $0.name == formula })
        let caskItem = try #require(harness.store.allItems.first { $0.name == cask })
        return (harness.store, (formulaItem, caskItem))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
