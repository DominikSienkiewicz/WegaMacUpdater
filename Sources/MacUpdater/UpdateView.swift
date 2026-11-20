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
        scan.inspectedKey = nil
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
    /// Wega's current line — a quip or her state's line — which the band above the list
    /// speaks.
    let wegaLine: String

    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var policies: UpdatePolicyStore
    /// Scan results and the tasks that produce them live above the language re-key,
    /// so switching language mid-scan neither loses the list nor orphans the task.
    @EnvironmentObject private var scan: ScanStore

    /// Purely transient: a modal that no background task writes to, so it may die
    /// with the view tree.
    @State private var pinTarget: PinRequest? = nil
    /// UX-01: the exact visible batch the user is being asked to approve. Keeping the
    /// rows, rather than recomputing after the dialog opens, makes confirmation and
    /// execution one immutable decision.
    @State private var pendingUpdateTargets: [OutdatedItem] = []
    @State private var showUpdateConfirmation = false
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
            .sheet(item: $pinTarget) { req in
                PinVersionSheet(request: req) { version in
                    policies.pin(key: req.key, name: req.name, version: version)
                }
            }
            .sheet(isPresented: $scan.showPlanPreview) { planSheet }
            .confirmationDialog(
                trf("Zaktualizować %@ pozycji?", "\(pendingUpdateTargets.count)"),
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
                Text(pendingUpdateTargets.map(updateTargetDescription).joined(separator: "\n"))
            }
            .onChange(of: showUpdateConfirmation) { _, isPresented in
                if !isPresented { pendingUpdateTargets = [] }
            }
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
                isEnabled: scan.status != .checking && !scan.isRefreshing && !scan.updating,
                run: { scan.startCheck() }
            ))
            .focusedSceneValue(\.runUpdateAction, WegaMenuAction(
                isEnabled: scan.status == .results && allowsUpdateRun,
                run: { requestUpdate() }
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
    // The same scene the quiet launch refresh draws over the list — see `ScanProgressScene`,
    // which owns its own sizing and padding so this screen and that overlay cannot be given
    // different ones.
    private var checkingView: some View {
        ScanProgressScene(progress: scan.progress)
    }

    // MARK: Results
    private var resultsView: some View {
        VStack(spacing: 0) {
            // The band reports the scan and carries the update button; with nothing to update
            // the plain heading does. The list header carries select-all next to the categories.
            if hasUpdates {
                resultsBand
                    .padding(.horizontal, WegaLayout.listGutter)
                    .padding(.top, WegaLayout.sectionSpacing)
            }
            VStack(alignment: .leading, spacing: 12) {
                if !hasUpdates {
                    resultsHeading
                }
                listHeader
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WegaLayout.selectionColumnInset)
            .padding(.vertical, WegaLayout.sectionSpacing)

            // Everything below the header is what a running update could be raced by, so for
            // the run's duration it is inert and covered by the run itself — see
            // `UpdateRunOverlay`. The overlay sits outside `.disabled`, so its stop button
            // stays live.
            screenBody
                .disabled(!ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating))
                .overlay {
                    if scan.updating {
                        updateRunOverlay
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: scan.updating)
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
            groupingMenu
        }
    }

    /// The dusk band: what the scan found, the queue, and the round update button. It is the
    /// whole path to an update — the button takes today's gate, help text and confirmation.
    private var resultsBand: some View {
        let presentation = bandPresentation
        return UpdateBand(
            presentation: presentation,
            refreshProgress: scan.isRefreshing ? scan.progress : nil,
            planLinkEnabled: ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating),
            onShowPlan: { scan.showPlanPreview = true },
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
            protection:    scan.caskProtection
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
            incompleteNote: scan.lastScanComplete ? nil : tr("sprawdzenie niepełne")
        )
    }

    private var resultsHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.wega(.largeTitle, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let date = scan.lastCheck {
                let freshness = scan.freshness() ?? .fresh
                VStack(alignment: .leading, spacing: 3) {
                    Text(freshness == .stale
                         ? trf("Znaleziono %@", "\(date.formatted(date: .abbreviated, time: .shortened))")
                         : trf("Sprawdzono %@", "\(date.formatted(date: .omitted, time: .shortened))"))
                    // UX-19 — while a scan runs in place, the header shows each source's
                    // phase instead of the stamp naming the sources of the result below.
                    if scan.isRefreshing {
                        ScanPhaseStrip(progress: scan.progress)
                    } else {
                        Text(sourceStamp)
                    }
                }
                .font(.wega(.subheadline))
                .foregroundStyle(freshness.needsExplicitTimestamp ? AnyShapeStyle(Color.wegaToffee) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// REL-12 — the longest operation in the app has a stop button. It does not kill the
    /// package manager mid-install; it stops the run at the next package boundary, which is
    /// the only safe place to stop.
    private var updateRunOverlay: some View {
        UpdateRunOverlay(
            isStopping: scan.updateInterruption.isRequested,
            logLines:   scan.showLog ? scan.brewLog : nil,
            onCancel:   { scan.cancelUpdate() },
            onShowLog:  { scan.showLog = true },
            onHideLog:  { scan.showLog = false },
            progress:   {
                if scan.updating, let progress = scan.upgradeProgress {
                    UpgradeProgressBar(progress: progress)
                }
            }
        )
    }

    @ViewBuilder
    private var screenBody: some View {
        VStack(spacing: 0) {
            ScanBannerHost(onNavigate: onNavigate)

            staleCaskCard

            PasswordPromptCallout(queuedNeedingPassword: updateTargets.filter {
                $0.kind == .cask && scan.caskProfiles[$0.name]?.mayRequireAdminPassword == true
            }.map(\.name))

            // The rows on screen are the ones the scan is in the middle of replacing, so for
            // its duration they are a report, not a menu: inert, and with the scan drawn over
            // them behind a material that stands them down. Without this the only sign of a
            // launch refresh was a line of small print in the header, over a list that looked
            // exactly like a finished one.
            listColumn
                .frame(maxWidth: .infinity)
                .disabled(!ScanSelectionGate.allowsSelection(isRefreshing: scan.isRefreshing))
                .overlay {
                    if ScanSelectionGate.coversList(isRefreshing: scan.isRefreshing, showsRows: showsRows) {
                        ScanBusyOverlay(progress: scan.progress)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: scan.isRefreshing)
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

    /// UX-18 — urgency or source; shown whenever there is a list to group.
    @ViewBuilder
    private var groupingMenu: some View {
        if scan.scopeCounts.all > 0 {
            Picker(tr("Grupuj"), selection: $grouping) {
                ForEach(UpdateGrouping.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    // MARK: Band

    /// Whether the scan left anything to show, restarts included — what `listColumn` (rows or
    /// an empty state) reads.
    private var hasResults: Bool {
        !(allItems.isEmpty && visibleManual.isEmpty && scan.restartCandidates.isEmpty)
    }

    /// Whether the scan found anything to update — what `resultsView` (band or plain heading)
    /// reads. Apps that only wait for a restart keep today's "Wszystko aktualne" heading.
    private var hasUpdates: Bool {
        !(allItems.isEmpty && visibleManual.isEmpty)
    }

    /// Whether the list shows rows rather than one of its empty states — the one answer
    /// `listColumn` and the scan overlay over it both read.
    private var showsRows: Bool {
        hasResults && (filterHasContent(updateFilter) || !scan.restartCandidates.isEmpty)
    }

    @ViewBuilder
    private var listColumn: some View {
        if !hasResults {
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
        } else if showsRows {
            ScrollView {
                LazyVStack(spacing: WegaLayout.sectionSpacing) {
                    switch grouping {
                    case .urgency: urgencyGroupedSections
                    case .source:  sourceGroupedSections
                    }
                    if !scan.restartCandidates.isEmpty {
                        RestartSection(
                            candidates: scan.restartCandidates,
                            busyProcess: scan.restartBusy,
                            onRestart: { info in Task { await scan.restartApp(info) } },
                            pendingForce: scan.pendingForceRestart,
                            onForce: { info in Task { await scan.confirmForceRestart(info) } },
                            onKeepOpen: { info in scan.keepAppOpen(info) }
                        )
                    }
                    // During a run the log lives in `UpdateRunOverlay`; a second copy
                    // under it would only be covered.
                    if scan.showLog && !scan.updating {
                        BrewLogPanel(lines: scan.brewLog, tapTrust: scan.tapTrustActions) { scan.showLog = false }
                    }
                }
                .padding(WegaLayout.listGutter)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            EmptyHero(
                pose: .idle,
                title: tr("Nic w tej kategorii"),
                message: tr("W tej kategorii nie ma teraz aktualizacji. Przełącz kategorię nad listą."),
                compact: true
            )
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
                                Text(tr("Sprawdzam rozmiary pobrań…")).font(.wega(.subheadline)).foregroundStyle(.tertiary)
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
                title: trf("%@ casków bez aplikacji", "\(scan.staleCasks.count)"),
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

    /// M4 — the header names both halves of the count, because they behave differently:
    /// the installable ones are what the button below will actually upgrade.
    private var headline: String {
        let count = scan.updateCount
        if count.isEmpty { return tr("Wszystko aktualne") }
        if count.manual == 0 {
            return trf("%@ aktualizacji do zainstalowania", "\(count.installable)")
        }
        if count.installable == 0 {
            return trf("%@ do ręcznej aktualizacji", "\(count.manual)")
        }
        return trf("%@ do zainstalowania + %@ ręcznych", "\(count.installable)", "\(count.manual)")
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

    private func updateTargetDescription(_ item: OutdatedItem) -> String {
        switch item.kind {
        case .formula:  return "\(tr("Homebrew Formulae")): \(item.name)"
        case .cask:     return "\(tr("Homebrew Casks")): \(item.name)"
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
    private func filterHasContent(_ filter: UpdateFilter) -> Bool {
        switch filter {
        case .all:      return !allItems.isEmpty || !visibleManual.isEmpty
        case .apps:     return allItems.contains { $0.kind.category == .apps } || !visibleManual.isEmpty
        case .cli:      return allItems.contains { $0.kind.category == .cli }
        case .security: return visibleManual.contains(where: scan.isSecurityApp)
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

/// One cask in the plan preview (F2): download host, checksum status, rollback coverage,
/// a possible admin-password prompt, and the download size.
///
/// Every field is allowed to say "I don't know". `brew info --json` has no size, so a size
/// is a HEAD probe away and a CDN may still withhold `Content-Length`; a `pkg`/`installer`/
/// `preflight` stanza is visible but its contents are not, so the password note says *may*.
private struct PlanPreviewCaskRow: View {
    let token: String
    let download: CaskDownloadInfo?
    let protection: RollbackProtection.Verdict?
    let mayNeedPassword: Bool
    let size: DownloadSizeProbeResult?

    private var host: String {
        download?.url.flatMap { URL(string: $0)?.host() } ?? tr("nieznany host")
    }

    private var sizeLabel: String {
        switch size {
        case .known(let bytes):
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .unknown, .failed:
            return tr("rozmiar nieznany")
        case nil:
            return "—"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(token)
                    .font(.wega(.subheadline, weight: .medium, monospaced: true))
                    .frame(width: 150, alignment: .leading)
                Text(host)
                    .font(.wega(.footnote))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if download?.hasChecksum == true {
                    Label(tr("suma zostanie sprawdzona"), systemImage: "checkmark.seal")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help(tr("suma zostanie sprawdzona"))
                } else {
                    Label(tr("źródło nie podaje sumy do sprawdzenia"), systemImage: "exclamationmark.shield")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.wegaDanger)
                        .help(tr("źródło nie podaje sumy do sprawdzenia"))
                }
                if protection == .protected {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(Color.wegaSuccess)
                        .help(RollbackScopePresentation.notice(for: RollbackProtection.scope(token: token))?.localizedDescription
                              ?? tr("Chronione automatycznym cofnięciem"))
                } else if protection != nil {
                    Image(systemName: "shield.slash").foregroundStyle(.tertiary)
                        .help(tr("Bez ochrony cofnięciem"))
                }
                if mayNeedPassword {
                    Image(systemName: "key").foregroundStyle(Color.wegaToffee)
                        .help(tr("Może poprosić o hasło administratora."))
                }
                Text(sizeLabel)
                    .font(.wega(.footnote, monospaced: true))
                    .foregroundStyle(.tertiary)
                    .frame(width: 96, alignment: .trailing)
            }
            .font(.wega(.subheadline))
            if protection == .protected {
                RollbackScopeNotice(scope: RollbackProtection.scope(token: token))
            }
        }
    }
}

/// UX-14 — what the selection says: its text, and how much of it the rollback net covers
/// (the band reads `protectionText`).
struct UpdateActionBarSummary: Equatable {
    let selectedCount: Int
    let visibleCount: Int
    let protectedCount: Int

    init(
        selectedCount: Int,
        visibleCount: Int,
        targets: [OutdatedItem],
        protection: [String: RollbackProtection.Verdict]
    ) {
        self.selectedCount = selectedCount
        self.visibleCount = visibleCount
        self.protectedCount = targets.filter { $0.kind == .cask && protection[$0.name] == .protected }.count
    }

    /// An empty selection says what is missing instead of offering a dead button silently.
    var selectionText: String {
        selectedCount == 0
            ? tr("Zaznacz, co mam zaktualizować")
            : trf("%@ z %@ zaznaczonych", "\(selectedCount)", "\(visibleCount)")
    }

    /// Only casks the rollback net covers count; the band says nothing rather than zero.
    var protectionText: String? {
        protectedCount == 0 ? nil : trf("%@ z automatycznym cofnięciem", "\(protectedCount)")
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
                title: tr("Homebrew Formulae"), subtitle: tr("narzędzia CLI"), tint: .wegaInfo,
                items: formulae,
                rollbackCaption: Self.rollbackCaption(for: .formula),
                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                onInspect: { scan.inspectedKey = $0.key }
            )
        }
        if !casks.isEmpty && updateFilter.allowsApps {
            UpdateSection(
                title: tr("Homebrew Casks"), subtitle: tr("aplikacje .app"), tint: .wegaLavender,
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
        // cask (Postman, ChatGPT…) stays under "Homebrew Casks" so
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
                title: tr("Homebrew Casks"),
                tint: .wegaToffee,
                subtitle: tr("samoaktualizujące się"),
                caption: tr("Homebrew nie pilnuje wersji tych apek (auto_updates) — robią to same. Wega sprawdza je u źródła."),
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
                caption: tr("Bez automatycznego cofnięcia — poprzednią wersję pobierzesz od wydawcy."),
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
                title: tr("Wymaga Twojego ruchu"),
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

// MARK: - Bottom bar chrome (UX-20)

/// The chrome of the bar at the bottom of the Updates list. Until stage 3 only the running
/// update (`UpdateRunOverlay`) uses it; the action bar it was shared with became the band.
///
/// Its content is padded from the column edge by `selectionColumnInset`, so the bar lines up
/// with the column every group header and package row uses, while the glass behind it is
/// inset by the list gutter.
struct WegaBottomBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, WegaLayout.selectionColumnInset)
            .padding(.trailing, WegaLayout.listGutter + WegaLayout.actionBarInnerPadding)
            .padding(.vertical, WegaLayout.actionBarInnerPadding)
            .background {
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, WegaLayout.listGutter)
            }
            .padding(.bottom, WegaLayout.listGutter)
    }
}

extension View {
    func wegaBottomBar() -> some View { modifier(WegaBottomBar()) }
}
