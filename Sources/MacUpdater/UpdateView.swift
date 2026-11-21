import AppKit
import SwiftUI
import MacUpdaterCore

/// The update currently shown in the inspector pane — either a package-manager-tracked
/// item (brew/mas/npm) or a manually-checked app. Module-internal (not `private`) so
/// `InspectorPane`, in its own file, can render it.
enum InspectedUpdate: Equatable {
    case outdated(OutdatedItem, iconPath: URL?)
    case manual(ManualOutdatedApp)
}

@MainActor
enum UpdateFilterInteraction {
    static func apply(_ filter: UpdateFilter, to scan: ScanStore) {
        // Every row is listed under "all", so its inspection stays: a menu-bar row (UXP-17)
        // sets it before the window it opens re-applies the filter.
        if filter != .all { scan.inspectedKey = nil }
        scan.restrictSelection(to: filter)
    }
}

struct UpdateView: View {
    var onWegaState:   ((WegaState) -> Void)?
    var onBadgeChange: ((Int) -> Void)?
    var onNavigate:    ((SidebarTab) -> Void)?
    var onErrorCount:  ((Int) -> Void)?
    /// Drives the sidebar tab icon: spins while busy, then green (ok) / red (error).
    var onActivity:    ((UpdateActivity) -> Void)?
    /// Drives the window's status footer: last scan time + count of manual updates
    /// whose release notes look like a security fix.
    var onFooterInfo:  ((Date?, Int) -> Void)? = nil
    /// Which category of updates to show, picked in the scope bar above the list (UX-16) and
    /// carried in the window's selection. Defaults to showing everything.
    var updateFilter:     UpdateFilter = .all
    /// Reports (apps count, CLI count) after each scan, for sidebar badges.
    var onCategoryCounts: ((Int, Int) -> Void)? = nil
    /// LT-01 — how many updates can still be taken back, for the „Cofnij aktualizacje”
    /// badge. Reported from here, not from `RollbackView`, because this view stays mounted
    /// for the whole session: the badge is right before that destination is ever opened.
    var onUndoableCount:  ((Int) -> Void)? = nil
    /// UX-16 — the scope bar picks a category; the selection that carries it is the window's.
    var onScopeChange:    ((UpdateFilter) -> Void)? = nil
    /// UXP-35 — ⌘F's query, typed in the field `DetailColumn` mounts beside this view. It never
    /// filters the list; the row above the list answers it.
    var searchQuery: String = ""
    /// Wega's current line — a quip or her state's line — which the band above the list
    /// speaks.
    let wegaLine: String

    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var policies: UpdatePolicyStore
    /// Scan results and the tasks that produce them live above the language re-key,
    /// so switching language mid-scan neither loses the list nor orphans the task.
    @EnvironmentObject private var scan: ScanStore
    /// Read, never started, by the search's answer: the read asks the network for the cask catalog.
    @EnvironmentObject private var inventory: InventoryStore
    /// With `cleanup`, the counts that say whether that read may no longer match the disk.
    @EnvironmentObject private var migration: MigrationStore
    @EnvironmentObject private var cleanup: CleanupStore
    /// False while another destination covers this screen; see `EnvironmentValues.updatesOnScreen`.
    @Environment(\.updatesOnScreen) private var onScreen
    @Environment(\.openSettings) private var openSettings

    /// Purely transient: a modal that no background task writes to, so it may die
    /// with the view tree.
    @State private var pinTarget: PinRequest? = nil
    /// UX-01: the exact visible batch the user is being asked to approve. Keeping the
    /// rows, rather than recomputing after the dialog opens, makes confirmation and
    /// execution one immutable decision.
    @State private var pendingUpdateTargets: [OutdatedItem] = []
    @State private var showUpdateConfirmation = false
    /// UXP-11 — the sheet behind "Ukryte przez Twoje reguły".
    @State private var showsHiddenRules = false
    /// UX-18 — how the list is grouped; by urgency unless the user picks by source.
    @AppStorage(UpdateGrouping.storageKey) private var grouping: UpdateGrouping = .default

    private var allItems: [OutdatedItem] { scan.allItems }
    private var visibleItems: [OutdatedItem] { scan.visibleItems(for: updateFilter) }
    private var visibleManual: [ManualOutdatedApp] { scan.visibleManual }
    private var updateTargets: [OutdatedItem] { scan.updateTargets(for: updateFilter) }
    private var updateTargetKeys: Set<String> { Set(updateTargets.map(\.key)) }
    private var selectedVisibleCount: Int {
        scan.selected.intersection(visibleItems.map(\.key)).count
    }
    /// One answer for the button and for ⌘⏎. They used to carry the condition separately and
    /// had already drifted; both now miss the same way when a scan is running.
    private var allowsUpdateRun: Bool {
        ScanSelectionGate.allowsUpdateRun(
            isRefreshing: scan.isRefreshing,
            isUpdating:   scan.updating,
            hasTargets:   !updateTargets.isEmpty
        )
    }
    /// A disabled control has to say which of its reasons is the live one — the tooltip used
    /// to blame an empty selection even when the real answer was "a scan is running".
    private var updateButtonHelp: String {
        if scan.updating { return tr("Aktualizuję wybrane pakiety") }
        return scan.isRefreshing
            ? tr("Najpierw skończę skanowanie — lista zaraz się zmieni.")
            : tr("Zaznacz przynajmniej jedną pozycję — Wega nie aktualizuje niczego, czego sam nie wskażesz.")
    }

    var body: some View {
        content
            .disabled(!onScreen)
            .sheet(item: $pinTarget) { req in
                PinVersionSheet(request: req) { version in
                    policies.pin(key: req.key, name: req.name, version: version)
                }
            }
            .sheet(isPresented: $scan.showPlanPreview) { planSheet }
            .sheet(isPresented: $showsHiddenRules) {
                PolicyRulesSheet(entries: scan.rulesHidingResults, onRestore: { policies.remove(key: $0.key) })
            }
            .confirmationDialog(
                trp("Zaktualizować %@ pozycji?", pendingUpdateTargets.count),
                isPresented: $showUpdateConfirmation,
                titleVisibility: .visible
            ) {
                Button(trf("Zaktualizuj wybrane (%@)", "\(pendingUpdateTargets.count)")) {
                    let targetKeys = Set(pendingUpdateTargets.map(\.key))
                    pendingUpdateTargets = []
                    Task { await scan.runUpdate(targetKeys: targetKeys) }
                }
                Button(tr("Anuluj"), role: .cancel) { pendingUpdateTargets = [] }
            } message: {
                Text(updateTargetLines(pendingUpdateTargets))
            }
            .onChange(of: showUpdateConfirmation) { _, isPresented in
                if !isPresented { pendingUpdateTargets = [] }
            }
            .wegaAttention(showUpdateConfirmation || scan.pendingForceRestart != nil)
            .wegaAttention(scan.runReport.map { $0.status != .finished } ?? false)
            // Switching the sidebar category re-filters the list but not the inspector's
            // resolver, so a selection made in one category would otherwise keep showing in
            // the pane after switching away from it. Clear it so the detail pane never
            // describes an item that's no longer in the visible list.
            .onChange(of: updateFilter) { _, filter in
                UpdateFilterInteraction.apply(filter, to: scan)
            }
            .onAppear {
                // The tree this view sits in is rebuilt whenever the language re-keys it
                // (and whenever the sidebar tab changes), handing us fresh closures over
                // fresh `@State`. Re-bind, then replay the last scan so the sidebar badges
                // and footer match the list the store still holds.
                scan.attach(model: model)
                scan.bind(ScanSinks(
                    wegaState:      onWegaState,
                    badgeChange:    onBadgeChange,
                    errorCount:     onErrorCount,
                    activity:       onActivity,
                    footerInfo:     onFooterInfo,
                    categoryCounts: onCategoryCounts,
                    undoableCount:  onUndoableCount
                ))
                // M2 — put the previous result on screen before doing anything else. It is
                // a no-op after the first appearance and whenever a scan has already run.
                scan.restoreLastScan()
                // UXP-05 — the store outlives the window and `restoreLastScan` is one-shot, so a
                // window reopened by a notification click adopts the round that arrived while it
                // was closed here, not through the subscription below (which skips the current value).
                if let background = MenuBarAgent.shared.lastResult {
                    scan.adoptBackgroundResultIfNewer(background)
                }
                scan.replayLastScan()
                // LT-01 — count what can still be undone (incl. whatever launch-time
                // recovery just settled) for the „Cofnij aktualizacje” badge. The list
                // itself is shown by `RollbackView`, which refreshes it again on arrival.
                scan.refreshUndoableUpdates()
                UpdateFilterInteraction.apply(updateFilter, to: scan)
                // The restored list is the *previous* answer, and nothing but a scan makes it
                // the current one. Correct it without taking the window away from it — see
                // `startLaunchRefresh()`. One-shot, so a tab switch does not re-trigger it.
                scan.startLaunchRefresh()
            }
            // UXP-05 — a later background round replaces the list too. `dropFirst` skips the
            // value that is already there: `restoreLastScan` weighs that one against the snapshot.
            .onReceive(MenuBarAgent.shared.$lastResult.dropFirst().compactMap { $0 }) { result in
                scan.adoptBackgroundResultIfNewer(result)
            }
            // UX-10 — expose the scan and the "Zaktualizuj…" action to the menu bar (⌘R, ⌘⏎).
            // `UpdateView` stays mounted for the whole session, so these are the window's
            // scan hooks regardless of which destination is on screen; the menu itself gates
            // ⌘⏎ to the Updates destination.
            .focusedSceneValue(\.startCheckAction, WegaMenuAction(
                isEnabled: scan.canStartCheck,
                run: { scan.startCheck() }
            ))
            .focusedSceneValue(\.runUpdateAction, WegaMenuAction(
                isEnabled: scan.status == .results && allowsUpdateRun && scan.runReport == nil,
                run: { requestUpdate() }
            ))
            // UXP-23 — ⌘. cancels the store's scan when no update runs; ⇧⌘A asks the select-all
            // checkbox's gate, and only while the list is the one on screen.
            .focusedSceneValue(\.cancelScanAction, WegaMenuAction(
                isEnabled: scan.canCancelScan,
                run: { scan.cancelScan() }
            ))
            .focusedSceneValue(\.selectAllVisibleAction, WegaMenuAction(
                isEnabled: scan.status == .results && !visibleItems.isEmpty
                    && ScanSelectionGate.allowsListSelection(isRefreshing: scan.isRefreshing, isUpdating: scan.updating) && scan.runReport == nil,
                run: { scan.selectAllVisible(filter: updateFilter) }
            ))
    }

    @ViewBuilder
    private var content: some View {
        switch scan.status {
        case .ready:    readyView
        case .checking: checkingView
        case .results:  resultsView
        }
    }

    // MARK: Ready
    private var readyView: some View {
        EmptyHero(
            pose: .idle,
            title: tr("Sprawdźmy, co się zestarzało"),
            // UX-06 — name every source Wega will check (Homebrew, Mac App Store, npm and the
            // manually-checked apps), not just the first two. Before a scan we can't know which
            // are installed, so this lists what the scan covers rather than a frozen subset.
            message: SourceCommunication.readyMessage(for: ScanSource.allCases),
            action: AnyView(
                Button { scan.startCheck() } label: {
                    Label(tr("Sprawdź aktualizacje"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            )
        )
    }

    // MARK: Checking
    //
    // The first scan's scene — see `ScanProgressScene`, which owns its own sizing and padding.
    // A scan over a result draws no scene, the check after a run included: the band and the
    // list header report it (UXP-13).
    private var checkingView: some View {
        ScanProgressScene(progress: scan.progress, catalogRefreshing: scan.isRefreshingCatalog)
    }

    // MARK: Results
    private var resultsView: some View {
        VStack(spacing: 0) {
            // The band reports the scan, the run, its check and its summary, and carries the update
            // button; without any of them the plain heading does. The list header carries select-all,
            // and gives its row to the summary's header while the summary is open.
            if showsBand {
                resultsBand
                    .padding(.horizontal, WegaLayout.listGutter)
                    .padding(.top, WegaLayout.sectionSpacing)
            }
            VStack(alignment: .leading, spacing: 12) {
                if !showsBand {
                    resultsHeading
                }
                if scan.runReport != nil {
                    UpdateRunSummaryHeader(remainingCount: scan.scopeCounts.all, onClose: { scan.closeRunReport() })
                } else {
                    listHeader
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WegaLayout.selectionColumnInset)
            .padding(.vertical, WegaLayout.sectionSpacing)

            // Everything below the header is what a running update could be raced by, so for
            // the run's duration `.disabled` makes it inert. Nothing is drawn over the rows (C2):
            // the band above carries the run and its stop, and the run's log below the list
            // stays live with it, both outside the disabled screen.
            screenBody
                .disabled(!ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating))
            if scan.updating && scan.showLog {
                BrewLogPanel(lines: scan.brewLog, onClose: { scan.showLog = false })
                    .padding(.horizontal, WegaLayout.listGutter)
                    .padding(.bottom, WegaLayout.listGutter)
            }
        }
    }

    /// The list's header row: the list-wide queue circle, the scope bar and the grouping menu.
    private var listHeader: some View {
        HStack(spacing: WegaLayout.checkboxSpacing) {
            // Select-all row. It sits outside `listColumn` and `screenBody`, so it inherits
            // neither of their disabled regions and carries both gates itself.
            if !visibleItems.isEmpty {
                SelectionCheckbox(
                    state: selectAllState,
                    accessibilityLabel: tr("Zaznacz wszystko"),
                    accessibilityValue: selectionSummary,
                    toggle: { scan.toggleAll(filter: updateFilter) }
                )
                .disabled(!ScanSelectionGate.allowsListSelection(isRefreshing: scan.isRefreshing, isUpdating: scan.updating))
            } else {
                QueueColumnPlaceholder()
            }
            scopeBar
            Spacer(minLength: 0)
            groupingControl
        }
    }

    /// The dusk band: what the scan found, the queue, and the round update button. It is the
    /// whole path to an update — the button takes today's gate, help text and confirmation.
    ///
    /// REL-12 — while the update runs the band carries its stop. It does not kill the package
    /// manager mid-install; it stops the run at the next package boundary, which is the only
    /// safe place to stop.
    private var resultsBand: some View {
        let presentation = bandPresentation
        return UpdateBand(
            presentation: presentation,
            scan: scan.isRefreshing ? scanPresentation : nil,
            run: scan.updating ? runPresentation : nil,
            planLinkEnabled: ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating),
            onShowPlan: { scan.showPlanPreview = true },
            onStop: { scan.cancelUpdate() },
            onShowLog: { scan.showLog = true },
            summary: scan.runReport.map(summaryPresentation),
            onCloseSummary: { scan.closeRunReport() },
            action: { layout in
                UpdateBandButton(
                    title: presentation.buttonTitle,
                    count: presentation.buttonCount,
                    accessibilityLabel: presentation.buttonAccessibilityLabel,
                    diameter: layout.buttonDiameter,
                    action: requestUpdate
                )
                .disabled(!allowsUpdateRun)
                .help(updateButtonHelp)
            }
        )
    }

    private var bandPresentation: UpdateBandPresentation {
        let counts = scan.scopeCounts
        let summary = UpdateActionBarSummary(
            selectedCount: selectedVisibleCount,
            visibleCount:  visibleItems.count,
            targets:       updateTargets,
            protection:    scan.caskProtection,
            resolved:      scan.caskProtectionResolved
        )
        return UpdateBandPresentation(
            totalCount:     counts.all,
            urgentCount:    counts.security,
            queueCount:     updateTargets.count,
            protectionText: summary.protectionText,
            lastCheck:      scan.lastCheck,
            freshness:      scan.freshness() ?? .fresh,
            sources:        UpdateBandPresentation.SourceChip.chips(from: scan.sourceReports),
            wegaLine:       wegaLine,
            incompleteNote: scan.lastScanComplete ? nil : tr("skan niepełny"),
            handOffCount:   scan.handOffCount(for: updateFilter),
            catalogAgeMinutes: scan.catalogAgeMinutes
        )
    }

    /// UXP-13 — the band's scan state, from what the store knows about the scan running now.
    private var scanPresentation: UpdateBandScanPresentation {
        UpdateBandScanPresentation(
            progress:          scan.progress,
            catalogRefreshing: scan.isRefreshingCatalog,
            startedAt:         scan.scanStartedAt,
            manual:            scan.manualScanProgress,
            foundSoFar:        scan.scopeCounts.all,
            checksRunResult:   scan.updating
        )
    }

    /// C2 stage 4 — the band's summary of the run on screen, read live for what can change
    /// under it: the check's completeness, the hand-offs and this run's undos.
    private func summaryPresentation(_ report: UpdateRunReport) -> UpdateBandSummaryPresentation {
        UpdateBandSummaryPresentation(
            report: report, scanComplete: scan.lastScanComplete,
            handOffCount: scan.handOffCount(for: .all),
            undoExpiry: UpdateBandSummaryPresentation.earliestUndoExpiry(of: report, in: scan.undoableUpdates)
        )
    }

    /// C2 stage 3 — the band's run state, from what the store knows about the run going now.
    private var runPresentation: UpdateBandRunPresentation {
        UpdateBandRunPresentation(
            progress:   scan.upgradeProgress,
            startedAt:  scan.runBoard.startedAt,
            isStopping: scan.updateInterruption.isRequested,
            logShown:   scan.showLog
        )
    }

    private var resultsHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Wszystko aktualne"))
                .font(.wega(.largeTitle, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let date = scan.lastCheck {
                let freshness = scan.freshness() ?? .fresh
                VStack(alignment: .leading, spacing: 3) {
                    Text(freshness == .stale
                         ? trf("Znaleziono %@", "\(date.formatted(date: .abbreviated, time: .shortened))")
                         : trf("Sprawdzono %@", "\(date.formatted(date: .omitted, time: .shortened))"))
                    // UX-19 — while a scan runs in place, the header shows each source's
                    // phase instead of the stamp naming the sources of the result below, and
                    // with no band to carry her, Wega sniffs beside it (UXP-13). One height
                    // for both, so the heading never jumps.
                    if scan.isRefreshing {
                        HStack(spacing: 8) {
                            WegaHead(pose: .sniff, size: 28).sniffing(true).accessibilityHidden(true)
                            ScanPhaseStrip(progress: scan.progress)
                        }
                        .frame(minHeight: 28, alignment: .leading)
                    } else {
                        Text(sourceStamp)
                            .frame(minHeight: 28, alignment: .leading)
                    }
                }
                .font(.wega(.subheadline))
                .foregroundStyle(freshness.needsExplicitTimestamp ? AnyShapeStyle(Color.wegaToffee) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var screenBody: some View {
        VStack(spacing: 0) {
            ScanBannerHost(onNavigate: onNavigate)

            // UXP-11 — in the column above the list, so it never lies on a row.
            if let notice = scan.ruleUndo {
                RuleUndoToast(notice: notice, onUndo: { scan.undoRuleChange() }, onClose: { scan.dismissRuleUndo(id: notice.id) })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            staleCaskCard

            PasswordPromptCallout(queuedNeedingPassword: updateTargets.filter {
                $0.kind == .cask && scan.caskProfiles[$0.name]?.mayRequireAdminPassword == true
            }.map(\.name))

            // UXP-35 — ⌘F answers above the list and never filters it.
            if let answer = searchAnswer {
                UpdatesSearchAnswerRow(answer: answer, inventoryReadAt: inventory.lastReadAt, inventoryProblem: inventory.errorMessage,
                                       onShow: showSearchMatch, onShowRules: { showRules(for: answer) },
                                       onOpenInventory: { onNavigate?(.inventory) })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            // C2 stage 4 — the run's result takes the rows' place until the summary closes. A run
            // that empties the list, or the category on screen, leaves it blank until then: no
            // hero and no empty category before the result.
            // Otherwise the rows on screen are the ones the scan is in the middle of replacing, so
            // for its duration they are a report, not a menu: inert. Nothing is drawn over them
            // (UXP-13) — the band and the list header say a scan is running and why the rows
            // cannot be selected, and every row stays readable.
            if let report = scan.runReport {
                UpdateRunSummaryList(report: report, onShowLog: { scan.showLog = true }, handOffs: {
                    UpdateRunHandOffGroup(onPinManual: requestPinManual)
                })
            } else if scan.updating && !showsRows {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listColumn
                    .frame(maxWidth: .infinity)
                    .disabled(!ScanSelectionGate.allowsSelection(isRefreshing: scan.isRefreshing))
                    .environment(\.updateRun, runListState)
            }
        }
    }

    /// What the locked list says about the run: each row's status, which rows step back, and
    /// the batches' notes on their group headers.
    private var runListState: UpdateRunListState? {
        scan.updating ? UpdateRunListState(board: scan.runBoard, isStopping: scan.updateInterruption.isRequested) : nil
    }

    /// The list's matches, or what Inventory already knows; nil while nothing is typed.
    private var searchAnswer: UpdatesSearchAnswer? {
        guard UpdatesSearch.normalized(searchQuery) != nil else { return nil }
        return UpdatesSearch.answer(
            query: searchQuery, rows: searchRows, hiddenByRules: scan.rulesHidingResults,
            inventory: inventory.lastReadAt == nil ? nil : inventory.apps,
            // A read that left sources out is no complete one either (REL-14).
            inventoryIsStale: inventory.isStale(given: InventoryChangeStamp.current(scan: scan, migration: migration, cleanup: cleanup, menuBar: MenuBarAgent.shared)) || inventory.errorMessage != nil,
            checks: InventoryCheckSource.checksByPath(scan: scan.installationChecks, scanCheckedAt: scan.lastCheck,
                                                      background: MenuBarAgent.shared.lastResult),
            policies: policies.policiesMap, now: Date()
        )
    }

    private var searchRows: [UpdatesSearch.Row] {
        UpdatesSearch.rows(items: allItems, visibleKeys: Set(visibleItems.map(\.key)), caskAppPaths: scan.caskIconPaths,
                           manual: visibleManual, filter: updateFilter, isSecurity: scan.isSecurityApp)
    }

    /// Opens a match in the inspector. One the category on screen hides brings back „Wszystkie”
    /// first, which keeps the inspection (`UpdateFilterInteraction`).
    private func showSearchMatch(_ row: UpdatesSearch.Row) {
        if !row.inCurrentScope { onScopeChange?(.all) }
        scan.inspectedKey = row.key
    }

    /// The rules sheet when it lists the rule the answer names; Settings → Paused updates otherwise.
    private func showRules(for answer: UpdatesSearchAnswer) {
        switch UpdatesSearch.rulesDestination(for: answer, hiddenByRules: scan.rulesHidingResults) {
        case .sheet: showsHiddenRules = true
        case .settings: SettingsRoute.shared.open(.policies, with: openSettings)
        }
    }

    /// UX-16 — shown once there is something to filter, and kept while a scope is applied so
    /// an empty category never strands the user without the way back.
    @ViewBuilder
    private var scopeBar: some View {
        let counts = scan.scopeCounts
        if counts.all > 0 || updateFilter != .all {
            UpdateScopeBar(filter: updateFilter, counts: counts) { onScopeChange?($0) }
        }
    }

    /// UX-18's grouping menu, or the note that says why the rows cannot be selected: while a
    /// scan runs in place over them, or while an update holds them — see `ListHeaderGroupingSlot`.
    private var groupingControl: some View {
        ListHeaderGroupingSlot(showsScanNote: ScanSelectionGate.coversList(isRefreshing: scan.isRefreshing, showsRows: showsRows), showsRunNote: scan.updating && showsRows, isStopping: scan.updateInterruption.isRequested) {
            groupingMenu
        }
    }

    /// UX-18 — urgency or source; shown whenever there is a list to group.
    @ViewBuilder
    private var groupingMenu: some View {
        if scan.scopeCounts.all > 0 {
            UpdateGroupingMenu(selection: $grouping)
        }
    }

    // MARK: Band

    /// Whether the scan left anything to show, restarts included — what `listColumn` (rows or
    /// an empty state) reads.
    private var hasResults: Bool {
        !(allItems.isEmpty && visibleManual.isEmpty && scan.restartCandidates.isEmpty)
    }

    /// Whether the scan found anything to update — what `showsBand` (band or plain heading)
    /// reads. Apps that only wait for a restart keep today's "Wszystko aktualne" heading.
    private var hasUpdates: Bool {
        !(allItems.isEmpty && visibleManual.isEmpty)
    }

    /// C2 stage 4 — the band also stays for a run, its check and its summary, even when the run
    /// emptied the list: its geometry never changes until the summary is closed.
    private var showsBand: Bool { hasUpdates || scan.updating || scan.runReport != nil }

    /// Whether the list shows rows rather than one of its empty states — the one answer
    /// `listColumn`, the list header's scan note and a run's blank area read.
    private var showsRows: Bool {
        hasResults && (Self.filterHasContent(updateFilter, items: allItems, manual: visibleManual, isSecurity: scan.isSecurityApp)
                       || !scan.restartCandidates.isEmpty)
    }

    @ViewBuilder
    private var listColumn: some View {
        let hiddenRuleCount = scan.rulesHidingResults.count
        if !hasResults {
            VStack(spacing: 0) {
                // REL-09 — an empty list only means "up to date" when the scan behind it heard
                // from every source. After a restart with the network down it used to mean
                // nothing at all, and said the most reassuring thing on the screen anyway.
                if scan.lastScanComplete {
                    EmptyHero(pose: .sleep, title: tr("Wszystko aktualne"), message: tr("Wega się zdrzemnie. Zajrzymy znowu za jakiś czas."), compact: true, playful: true)
                } else {
                    EmptyHero(pose: .sad,
                              title: tr("Nie wiem, czy wszystko aktualne"),
                              message: tr("Ostatni skan nie dostał odpowiedzi od wszystkich źródeł — pusta lista nic tu nie znaczy. Odśwież, gdy wróci połączenie."),
                              compact: true)
                }
                // UXP-11 — hiding the last update must not strand the way back.
                if hiddenRuleCount > 0 {
                    HiddenByRulesRow(count: hiddenRuleCount) { showsHiddenRules = true }
                        .padding(.bottom, WegaLayout.listGutter)
                }
                MissingAppHint(onOpenInventory: { onNavigate?(.inventory) })
                    .padding(.horizontal, WegaLayout.listGutter)
                    .padding(.bottom, WegaLayout.listGutter)
            }
        } else if showsRows {
            ScrollView {
                LazyVStack(spacing: WegaLayout.sectionSpacing) {
                    switch grouping {
                    case .urgency: urgencyGroupedSections
                    case .source:  sourceGroupedSections
                    }
                    if hiddenRuleCount > 0 {
                        HiddenByRulesRow(count: hiddenRuleCount) { showsHiddenRules = true }
                    }
                    MissingAppHint(onOpenInventory: { onNavigate?(.inventory) })
                    if !scan.restartCandidates.isEmpty {
                        RestartSection(
                            candidates: scan.restartCandidates,
                            busyProcess: scan.restartBusy,
                            onRestart: { info in Task { await scan.restartApp(info) } },
                            pendingForce: scan.pendingForceRestart,
                            onForce: { info in Task { await scan.confirmForceRestart(info) } },
                            onKeepOpen: { info in scan.keepAppOpen(info) },
                            onDismissForcePrompt: { info in scan.dismissForceRestartPrompt(info) }
                        )
                    }
                    // During a run the log sits under the list instead, outside the disabled
                    // screen (`resultsView`), without tap-trust buttons the busy mutex would refuse.
                    if scan.showLog && !scan.updating {
                        BrewLogPanel(lines: scan.brewLog, tapTrust: scan.tapTrustActions) { scan.showLog = false }
                    }
                }
                .padding(WegaLayout.listGutter)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            VStack(spacing: 0) {
                EmptyHero(
                    pose: .idle,
                    title: tr("Nic w tej kategorii"),
                    message: tr("W tej kategorii nie ma teraz aktualizacji. Przełącz kategorię nad listą."),
                    compact: true
                )
                if hiddenRuleCount > 0 {
                    HiddenByRulesRow(count: hiddenRuleCount) { showsHiddenRules = true }
                        .padding(.bottom, WegaLayout.listGutter)
                }
                MissingAppHint(onOpenInventory: { onNavigate?(.inventory) })
                    .padding(.horizontal, WegaLayout.listGutter)
                    .padding(.bottom, WegaLayout.listGutter)
            }
        }
    }

    /// F2 — "show me exactly what you will do", before anything is done.
    ///
    /// The commands are read from `UpdatePlanner.commands(for:)`, the same call the upgrade
    /// executes, so the preview cannot drift from reality. Per cask it reports the download
    /// host and whether Homebrew will verify its checksum, whether the rollback net covers
    /// it, whether the cask *may* ask for an admin password, and how big the download is —
    /// with **unknown** shown as itself, never as a guess.
    ///
    /// UX-14 — opened from the band as a sheet, so reading the plan no longer pushes
    /// the list down; it probes download sizes each time it opens, as the disclosure did.
    private var planSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Plan aktualizacji"))
                .font(.wega(.title3, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(scan.plannedCommands(targetKeys: updateTargetKeys).enumerated()), id: \.offset) { _, command in
                        Text("$ \(command.executable) \(command.arguments.joined(separator: " "))")
                            .font(.wega(.subheadline, monospaced: true))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !scan.plannedCaskTokens(targetKeys: updateTargetKeys).isEmpty {
                        Divider().opacity(0.4)
                        ForEach(scan.plannedCaskTokens(targetKeys: updateTargetKeys), id: \.self) { token in
                            PlanPreviewCaskRow(
                                token: token,
                                download: scan.caskDownloads[token],
                                protection: scan.caskProtection[token],
                                mayNeedPassword: scan.caskProfiles[token]?.mayRequireAdminPassword ?? false,
                                size: scan.caskSizes[token]
                            )
                        }
                        if scan.probingSizes {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(tr("Sprawdzam rozmiary pobrań…")).font(.wega(.subheadline)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(tr("Zamknij")) { scan.showPlanPreview = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 320, idealHeight: 460)
        .task { await scan.probeDownloadSizes(targetKeys: updateTargetKeys) }
    }

    /// M3(b) — offers the cleanup that "check for updates" used to perform behind the
    /// user's back. Names every cask it would remove; the scan already excluded them from
    /// the list above, so nothing here is load-bearing for the count.
    @ViewBuilder
    private var staleCaskCard: some View {
        if !scan.staleCasks.isEmpty {
            // UX-15 — an offer, not a fault: the shared callout's info level. The names stay
            // in the detail, unclipped, because they are what the button acts on.
            WegaCallout(
                .info,
                title: trp("%@ casków bez aplikacji", scan.staleCasks.count),
                symbol: "trash.fill"
            ) {
                Text(trf("Homebrew wciąż śledzi: %@. Aplikacji nie ma na dysku — możesz je wyrejestrować.", "\(scan.staleCasks.joined(separator: ", "))"))
                    .font(.wega(.subheadline)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                Button(tr("Nie teraz")) { scan.dismissStaleCasks() }
                    .disabled(scan.cleaningStaleCasks)
                Button(tr("Wyrejestruj")) { Task { await scan.cleanUpStaleCasks() } }
                    .disabled(scan.cleaningStaleCasks)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// UX-06 — the monospaced stamp naming the sources behind the result on screen, built
    /// from the sources that were actually active in the scan. A detail-less result (a
    /// background-agent list or a legacy snapshot) has no per-source picture, so it falls
    /// back to naming every source Wega checks rather than showing nothing.
    private var sourceStamp: String {
        let active = ScanSource.active(in: scan.sourceReports)
        return SourceCommunication.stamp(for: active.isEmpty ? ScanSource.allCases : active)
    }

    private var selectAllState: SelectAllState {
        UpdatePlanner.selectAllState(selectedCount: selectedVisibleCount, totalCount: visibleItems.count)
    }

    private var selectionSummary: String {
        trf("%@ z %@ zaznaczonych", "\(selectedVisibleCount)", "\(visibleItems.count)")
    }

    private func requestUpdate() {
        let targets = updateTargets
        guard !targets.isEmpty else { return }
        pendingUpdateTargets = targets
        showUpdateConfirmation = true
    }

    private func updateTargetLines(_ items: [OutdatedItem]) -> String {
        let casks = items.filter { $0.kind == .cask }
        let labels = Dictionary(
            zip(casks.map(\.name), CaskDisplayName.labels(for: casks.map { ($0.name, scan.caskIconPaths[$0.name]) })),
            uniquingKeysWith: { first, _ in first })
        return items.map { updateTargetDescription($0, caskLabel: labels[$0.name]) }.joined(separator: "\n")
    }

    private func updateTargetDescription(_ item: OutdatedItem, caskLabel: String?) -> String {
        switch item.kind {
        case .formula:  return "\(tr("Narzędzia Homebrew")): \(item.name)"
        case .cask:     return "\(tr("Aplikacje Homebrew")): \(caskLabel ?? item.name)"
        case .appStore: return "\(tr("Mac App Store")): \(item.name)"
        case .npm:      return "npm: \(item.name)"
        }
    }

    // MARK: Pin

    private func requestPin(_ item: OutdatedItem) {
        pinTarget = PinRequest(key: item.policyKey, name: item.name, suggestedVersion: item.from ?? item.to ?? "")
    }

    private func requestPinManual(_ app: ManualOutdatedApp) {
        pinTarget = PinRequest(key: app.policyKey, name: app.name, suggestedVersion: app.installedVersion ?? app.availableVersion ?? "")
    }

    /// Whether the given filter would surface at least one update section.
    static func filterHasContent(_ filter: UpdateFilter, items: [OutdatedItem], manual: [ManualOutdatedApp],
                                 isSecurity: (ManualOutdatedApp) -> Bool) -> Bool {
        switch filter {
        case .all:      return !items.isEmpty || !manual.isEmpty
        case .apps:     return items.contains { $0.kind.category == .apps } || !manual.isEmpty
        case .cli:      return items.contains { $0.kind.category == .cli }
        case .security: return manual.contains(where: isSecurity)
        }
    }

    // MARK: FEAT-03 — transparentność pobrania
    @ViewBuilder
    private func caskTransparencyNote(casks: [OutdatedItem]) -> some View {
        let noCheck = UpdatePlanner.casksWithoutChecksum(casks, downloads: scan.caskDownloads)
        if !noCheck.isEmpty {
            // UX-15 — a risk the user should weigh before updating: the callout's warning level.
            WegaCallout(
                .warning,
                title: tr("Bez weryfikacji sumy kontrolnej"),
                symbol: "exclamationmark.shield.fill"
            ) {
                Text(trf("Homebrew zainstaluje bez sprawdzenia sumy: %@", "\(noCheck.map(\.name).joined(separator: ", "))"))
                    .font(.wega(.subheadline)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                EmptyView()
            }
        }
    }
}

// MARK: - List groupings (UX-18)

extension UpdateView {
    /// The list grouped by package manager and install origin — the grouping the Inventory
    /// window shares, one choice away in the "Grupuj" menu (UX-18).
    @ViewBuilder
    private var sourceGroupedSections: some View {
        let formulae = visibleItems.filter { $0.kind == .formula }
        let casks    = visibleItems.filter { $0.kind == .cask }
        let store    = visibleItems.filter { $0.kind == .appStore }
        let npmPkgs  = visibleItems.filter { $0.kind == .npm }
        if !formulae.isEmpty && updateFilter.allowsCli {
            UpdateSection(
                title: tr("Narzędzia Homebrew"), subtitle: tr("narzędzia CLI"), tint: .wegaInfo,
                items: formulae,
                rollbackCaption: Self.rollbackCaption(for: .formula),
                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                onInspect: { scan.inspectedKey = $0.key }
            )
        }
        if !casks.isEmpty && updateFilter.allowsApps {
            UpdateSection(
                title: tr("Aplikacje Homebrew"), subtitle: tr("aplikacje .app"), tint: .wegaLavender,
                items: casks, iconPaths: scan.caskIconPaths, rollbackProtection: scan.caskProtection,
                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                onInspect: { scan.inspectedKey = $0.key }
            )
            caskTransparencyNote(casks: casks)
        }
        if !store.isEmpty && updateFilter.allowsApps {
            UpdateSection(
                title: tr("Mac App Store"), subtitle: tr("via mas-cli"), tint: .wegaLavender,
                items: store,
                rollbackCaption: Self.rollbackCaption(for: .appStore),
                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                onInspect: { scan.inspectedKey = $0.key }
            )
        }
        if !npmPkgs.isEmpty && updateFilter.allowsCli {
            UpdateSection(
                title: tr("npm globalne"), subtitle: tr("pakiety -g"), tint: .wegaInfo,
                items: npmPkgs,
                rollbackCaption: Self.rollbackCaption(for: .npm),
                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                onInspect: { scan.inspectedKey = $0.key }
            )
        }
        // Group manual updates by INSTALL ORIGIN (same axis the Inventory
        // window labels), not by update source. A self-updating Homebrew
        // cask (Postman, ChatGPT…) stays under "Aplikacje Homebrew" so
        // both windows agree it's Brew — only genuinely non-package-manager
        // apps land under "Ręcznie zainstalowane".
        let dockerManual = visibleManual.filter { DockerDesktopUpdatePolicy.isDocker($0) }
        let visibleDocker = updateFilter.isSecurityOnly ? dockerManual.filter(scan.isSecurityApp) : dockerManual
        if !visibleDocker.isEmpty && updateFilter != .cli {
            ManualUpdateSection(
                items: visibleDocker, busyToken: scan.manualBusy,
                onInstall: { token in Task { await scan.installManual(token: token) } },
                title: "Docker Desktop", tint: .wegaToffee,
                subtitle: tr("aktualizator producenta"),
                caption: tr("Domyślnie użyj aktualizatora Docker Desktop. Homebrew wymaga osobnego potwierdzenia i bezpiecznego zatrzymania."),
                inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreManual,
                onPin: requestPinManual, onSkip: scan.skipManual,
                onInspect: { scan.inspectedKey = "m:" + $0.path.path }
            )
        }
        if updateFilter == .all || updateFilter == .apps {
            ForEach(scan.unresolvedDockerItems) { item in
                UnresolvedDockerUpdateRow(item: item) { scan.inspectedKey = item.key }
            }
        }
        let serviceManual = visibleManual.filter { ServiceVendorUpdatePolicy.profile(for: $0) != nil }
        let visibleServices = updateFilter.isSecurityOnly ? serviceManual.filter(scan.isSecurityApp) : serviceManual
        if !visibleServices.isEmpty && updateFilter != .cli {
            ManualUpdateSection(
                items: visibleServices, busyToken: scan.manualBusy,
                onInstall: { token in Task { await scan.installManual(token: token) } },
                title: tr("Usługi aktualizowane przez producenta"), tint: .wegaToffee,
                subtitle: tr("aktualizator producenta"),
                caption: tr("Homebrew wskazuje wersję pakietu. Aktualizację wykonaj w aplikacji, zgodnie z polityką administratora."),
                inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreManual,
                onPin: requestPinManual, onSkip: scan.skipManual,
                onInspect: { scan.inspectedKey = "m:" + $0.path.path }
            )
        }
        if updateFilter == .all || updateFilter == .apps {
            ForEach(scan.unresolvedServiceItems) { item in
                UnresolvedServiceUpdateRow(item: item) { scan.inspectedKey = item.key }
            }
        }
        let manualGroups = UpdatePlanner.groupManual(visibleManual.filter {
            !DockerDesktopUpdatePolicy.isDocker($0) && ServiceVendorUpdatePolicy.profile(for: $0) == nil
        })
        let brewManual = updateFilter.isSecurityOnly ? manualGroups.brew.filter(scan.isSecurityApp) : manualGroups.brew
        if !brewManual.isEmpty && updateFilter != .cli {
            ManualUpdateSection(
                items: brewManual,
                busyToken: scan.manualBusy,
                onInstall: { token in Task { await scan.installManual(token: token) } },
                title: tr("Aplikacje Homebrew"),
                tint: .wegaToffee,
                subtitle: tr("samoaktualizujące się"),
                caption: tr("Homebrew nie pilnuje wersji tych aplikacji (auto_updates) — robią to same. Wega sprawdza je u źródła."),
                inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreManual,
                onPin: requestPinManual,
                onSkip: scan.skipManual,
                onInspect: { scan.inspectedKey = "m:" + $0.path.path }
            )
        }
        let manualOnly = updateFilter.isSecurityOnly ? manualGroups.manual.filter(scan.isSecurityApp) : manualGroups.manual
        if !manualOnly.isEmpty && updateFilter != .cli {
            ManualUpdateSection(
                items: manualOnly,
                busyToken: scan.manualBusy,
                onInstall: { token in Task { await scan.installManual(token: token) } },
                title: tr("Ręcznie zainstalowane"),
                tint: .wegaToffee,
                caption: tr("Bez automatycznego cofnięcia — poprzednią wersję pobierzesz od producenta."),
                inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreManual,
                onPin: requestPinManual,
                onSkip: scan.skipManual,
                onInspect: { scan.inspectedKey = "m:" + $0.path.path }
            )
        }
    }

    /// UX-18 — the list grouped by what the user does next: possible security fixes, then the
    /// apps and the tools Wega updates in a batch, then what the vendor or the user finishes.
    /// A card here mixes sources, so each row names its own source and rollback limit.
    @ViewBuilder
    private var urgencyGroupedSections: some View {
        let groups = UrgencyGroups.make(
            items: visibleItems, manual: visibleManual, filter: updateFilter, isSecurity: scan.isSecurityApp
        )
        if !groups.security.isEmpty {
            ManualUpdateSection(
                items: groups.security, busyToken: scan.manualBusy,
                onInstall: { token in Task { await scan.installManual(token: token) } },
                title: tr("Możliwe poprawki bezpieczeństwa"),
                tint: .wegaDanger, ordinal: groups.ordinal(of: .security),
                caption: tr("Wega rozpoznała je po notatkach wydania. Szczegóły są w inspektorze."),
                inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreManual,
                onPin: requestPinManual, onSkip: scan.skipManual,
                onInspect: { scan.inspectedKey = "m:" + $0.path.path }
            )
        }
        if !groups.apps.isEmpty {
            UpdateSection(
                title: tr("Aplikacje"), tint: .wegaLavender, ordinal: groups.ordinal(of: .apps),
                items: groups.apps, iconPaths: scan.caskIconPaths, rollbackProtection: scan.caskProtection,
                showsSource: true,
                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                onInspect: { scan.inspectedKey = $0.key }
            )
            caskTransparencyNote(casks: groups.apps.filter { $0.kind == .cask })
        }
        if !groups.cli.isEmpty {
            UpdateSection(
                title: tr("Narzędzia CLI"), tint: .wegaInfo, ordinal: groups.ordinal(of: .cli),
                items: groups.cli,
                showsSource: true,
                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                onInspect: { scan.inspectedKey = $0.key }
            )
        }
        if !groups.needsYou.isEmpty {
            ManualUpdateSection(
                items: groups.needsYou, busyToken: scan.manualBusy,
                onInstall: { token in Task { await scan.installManual(token: token) } },
                title: tr("Wymaga Twojego działania"),
                tint: .wegaToffee, ordinal: groups.ordinal(of: .needsYou),
                caption: tr("Te aktualizacje kończy producent albo Ty. Przy każdej Wega podpowiada, jak."),
                inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreManual,
                onPin: requestPinManual, onSkip: scan.skipManual,
                onInspect: { scan.inspectedKey = "m:" + $0.path.path }
            )
        }
        if updateFilter == .all || updateFilter == .apps {
            ForEach(scan.unresolvedDockerItems) { item in
                UnresolvedDockerUpdateRow(item: item) { scan.inspectedKey = item.key }
            }
            ForEach(scan.unresolvedServiceItems) { item in
                UnresolvedServiceUpdateRow(item: item) { scan.inspectedKey = item.key }
            }
        }
    }
}

extension UpdateView {
    /// LT-01 — a source Wega cannot roll back says so: under its header when the list is
    /// grouped by source, on each of its rows when grouped by urgency (UX-18), instead of
    /// letting the cask shield imply a net it does not have. Casks carry their own verdict.
    static func rollbackCaption(for kind: OutdatedItem.Kind) -> String? {
        switch kind {
        case .formula:  return tr("Bez automatycznego cofnięcia — Homebrew nie zachowuje poprzednich wersji formuł.")
        case .appStore: return tr("Bez automatycznego cofnięcia — App Store nie pozwala wrócić do poprzedniej wersji.")
        case .npm:      return tr("Bez automatycznego cofnięcia — npm nie zachowuje poprzednich wersji pakietów.")
        case .cask:     return nil
        }
    }
}
