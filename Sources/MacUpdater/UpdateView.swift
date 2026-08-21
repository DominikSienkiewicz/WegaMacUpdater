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
    /// Which category of updates to show, driven by the sidebar. Defaults to
    /// showing everything until the sidebar selection wires this up.
    var updateFilter:     UpdateFilter = .all
    /// Reports (apps count, CLI count) after each scan, for sidebar badges.
    var onCategoryCounts: ((Int, Int) -> Void)? = nil
    /// LT-01 — how many updates can still be taken back, for the „Cofnij aktualizacje”
    /// badge. Reported from here, not from `RollbackView`, because this view stays mounted
    /// for the whole session: the badge is right before that destination is ever opened.
    var onUndoableCount:  ((Int) -> Void)? = nil

    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var policies: UpdatePolicyStore
    /// Scan results and the tasks that produce them live above the language re-key,
    /// so switching language mid-scan neither loses the list nor orphans the task.
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.openSettings) private var openSettings

    /// Purely transient: a modal that no background task writes to, so it may die
    /// with the view tree.
    @State private var pinTarget: PinRequest? = nil
    /// UX-01: the exact visible batch the user is being asked to approve. Keeping the
    /// rows, rather than recomputing after the dialog opens, makes confirmation and
    /// execution one immutable decision.
    @State private var pendingUpdateTargets: [OutdatedItem] = []
    @State private var showUpdateConfirmation = false

    private var allItems: [OutdatedItem] { scan.allItems }
    private var visibleItems: [OutdatedItem] { scan.visibleItems(for: updateFilter) }
    private var visibleManual: [ManualOutdatedApp] { scan.visibleManual }
    private var updateTargets: [OutdatedItem] { scan.updateTargets(for: updateFilter) }
    private var updateTargetKeys: Set<String> { Set(updateTargets.map(\.key)) }
    private var selectedVisibleCount: Int {
        scan.selected.intersection(visibleItems.map(\.key)).count
    }

    var body: some View {
        content
            .sheet(item: $pinTarget) { req in
                PinVersionSheet(request: req) { version in
                    policies.pin(key: req.key, name: req.name, version: version)
                }
            }
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
                scan.replayLastScan()
                // LT-01 — count what can still be undone (incl. whatever launch-time
                // recovery just settled) for the „Cofnij aktualizacje” badge. The list
                // itself is shown by `RollbackView`, which refreshes it again on arrival.
                scan.refreshUndoableUpdates()
                UpdateFilterInteraction.apply(updateFilter, to: scan)
            }
            // UX-10 — expose the scan and the "Zaktualizuj…" action to the menu bar (⌘R, ⌘⏎).
            // `UpdateView` stays mounted for the whole session, so these are the window's
            // scan hooks regardless of which destination is on screen; the menu itself gates
            // ⌘⏎ to the Updates destination.
            .focusedSceneValue(\.startCheckAction, WegaMenuAction(
                isEnabled: scan.status != .checking && !scan.updating,
                run: { scan.startCheck() }
            ))
            .focusedSceneValue(\.runUpdateAction, WegaMenuAction(
                isEnabled: scan.status == .results && !scan.updating && !updateTargets.isEmpty,
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
    // M2(c) — this screen used to animate five invented command bars on a timer, regardless
    // of what the scan was doing or how long it would take, with no way to stop it. The scan
    // is strictly sequential, so the bar now reports the phase it is genuinely in.
    private var checkingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: scan.progress?.fractionCompleted ?? 0)
                .progressViewStyle(.linear)
                .tint(Color.wegaHoney)
                // A linear ProgressView reports a nonzero intrinsic width, which — with no
                // upper bound — propagates up and pushes the detail column wide enough to
                // shove the sidebar off-screen. Pin it elastic (0…∞) so it fills, not forces.
                .frame(minWidth: 0, maxWidth: .infinity)
            if case .running(let phase) = scan.progress {
                Text(phase.commandLabel)
                    .font(.wega(.subheadline, monospaced: true))
                    .foregroundStyle(.tertiary)
            }
            SniffingScene(
                caption: tr("Wega węszy po Homebrew…"),
                thoughts: [
                    tr("Czy ten cask jest świeży?"),
                    tr("Coś tu pachnie aktualizacją"),
                    tr("Sniff sniff… brew outdated"),
                    tr("Hmm, znajomy zapach Sparkle"),
                    tr("SHA256 się zgadza?"),
                    tr("Łapię trop wersji"),
                    "0x4A 0x65 0x6C 0x6C 0x79",
                    tr("Mhm… nowa wersja?"),
                    tr("Info.plist… mhm"),
                    tr("Ten cask wymaga odświeżenia")
                ]
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
        // The whole checking screen fills the detail column and demands no minimum of its
        // own, so the sidebar keeps the exact width (and inset) it has when idle.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    // MARK: Results
    private var resultsView: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.wega(.title2, weight: .semibold))
                    if let d = scan.lastCheck {
                        // M2 — a restored list must never pass for a fresh one. Anything
                        // older than a quarter of an hour carries its date, and a day-old
                        // result says so in words.
                        let freshness = scan.freshness() ?? .fresh
                        HStack(spacing: 4) {
                            Text(freshness == .stale
                                 ? trf("Znaleziono %@", "\(d.formatted(date: .abbreviated, time: .shortened))")
                                 : trf("Sprawdzono %@", "\(d.formatted(date: .omitted, time: .shortened))"))
                            Text("·")
                            Text(sourceStamp).font(.wega(.subheadline, monospaced: true))
                        }
                        .font(.wega(.subheadline))
                        .foregroundStyle(freshness.needsExplicitTimestamp ? AnyShapeStyle(Color.wegaToffee) : AnyShapeStyle(.tertiary))
                    }
                }
                Spacer()
                if !visibleItems.isEmpty {
                    // The batch button names the selection and nothing else. It used to read
                    // "Update all (N)" whenever nothing was ticked and upgrade every visible
                    // row on the first click — the widest possible action, one click deep,
                    // reached by doing nothing. Now an empty selection disables it, and the
                    // hint beside it says why rather than leaving a dead control unexplained.
                    if !scan.updating && updateTargets.isEmpty {
                        Text(tr("Zaznacz, co mam zaktualizować"))
                            .font(.wega(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    Button(action: requestUpdate) {
                        if scan.updating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(trf("Zaktualizuj wybrane (%@)", "\(updateTargets.count)"), systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoneyFill)
                    .foregroundStyle(Color.wegaInk)
                    .disabled(scan.updating || updateTargets.isEmpty)
                    .help(tr("Zaznacz przynajmniej jedną pozycję — Wega nie aktualizuje niczego, czego sam nie wskażesz."))

                    // REL-12 — the longest operation in the app finally has a stop button.
                    // It does not kill the package manager mid-install; it stops the run at
                    // the next package boundary, which is the only safe place to stop.
                    if scan.updating {
                        Button(scan.updateInterruption.isRequested
                               ? tr("Przerywam…")
                               : tr("Anuluj")) {
                            scan.cancelUpdate()
                        }
                        .disabled(scan.updateInterruption.isRequested)
                        .help(tr("Zatrzymam po bieżącym pakiecie — trwającej instalacji nie przerywam w połowie."))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if scan.updating, let progress = scan.upgradeProgress {
                UpgradeProgressBar(progress: progress)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let b = scan.banner {
                BannerView(
                    data: b,
                    onAction: { action in
                        switch action {
                        case .openLogs: onNavigate?(.logs)
                        case .openSettings:
                            openSettings()
                        case .openAppManagementSettings:
                            // REL-05 — straight to the pane that grants the permission,
                            // not to Wega's own settings, which cannot grant anything.
                            NSWorkspace.shared.open(AppManagementSettings.paneURL)
                        }
                    },
                    onClose: { scan.dismissBanner() }
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            planPreview

            staleCaskCard

            listColumn
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var listColumn: some View {
        if allItems.isEmpty && visibleManual.isEmpty && scan.restartCandidates.isEmpty {
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
        } else if filterHasContent(updateFilter) || !scan.restartCandidates.isEmpty {
            VStack(spacing: 0) {
                // Select-all row. It sits outside the cards, so it reproduces their inset
                // by hand (`selectionColumnInset`) and wears the row-sized glyph: this
                // control, every group header's checkbox and every package row's checkbox
                // form one column, and a stray offset made the widest of the three read as
                // an unrelated control floating in the middle of the screen.
                HStack(spacing: WegaLayout.checkboxSpacing) {
                    SelectionCheckbox(
                        state: selectAllState,
                        accessibilityLabel: tr("Zaznacz wszystko"),
                        accessibilityValue: selectionSummary,
                        toggle: { scan.toggleAll(filter: updateFilter) }
                    )
                    Text(selectedVisibleCount == 0 ? tr("Zaznacz wszystko") : selectionSummary)
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, WegaLayout.selectionColumnInset)
                .padding(.trailing, WegaLayout.listGutter)
                .padding(.vertical, 8)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        let formulae = visibleItems.filter { $0.kind == .formula }
                        let casks    = visibleItems.filter { $0.kind == .cask }
                        let store    = visibleItems.filter { $0.kind == .appStore }
                        let npmPkgs  = visibleItems.filter { $0.kind == .npm }
                        if !formulae.isEmpty && updateFilter.allowsCli {
                            UpdateSection(
                                title: tr("Homebrew Formulae"), subtitle: tr("narzędzia CLI"), icon: "terminal",
                                items: formulae,
                                rollbackCaption: tr("Bez automatycznego cofnięcia — Homebrew nie zachowuje poprzednich wersji formuł."),
                                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                                onInspect: { scan.inspectedKey = $0.key }
                            )
                        }
                        if !casks.isEmpty && updateFilter.allowsApps {
                            UpdateSection(
                                title: tr("Homebrew Casks"), subtitle: tr("aplikacje .app"), icon: "app.gift",
                                items: casks, iconPaths: scan.caskIconPaths, rollbackProtection: scan.caskProtection,
                                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                                onInspect: { scan.inspectedKey = $0.key }
                            )
                            caskTransparencyNote(casks: casks)
                        }
                        if !store.isEmpty && updateFilter.allowsApps {
                            UpdateSection(
                                title: tr("Mac App Store"), subtitle: tr("via mas-cli"), icon: "bag",
                                items: store,
                                rollbackCaption: tr("Bez automatycznego cofnięcia — App Store nie pozwala wrócić do poprzedniej wersji."),
                                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                                onInspect: { scan.inspectedKey = $0.key }
                            )
                        }
                        if !npmPkgs.isEmpty && updateFilter.allowsCli {
                            UpdateSection(
                                title: tr("npm globalne"), subtitle: tr("pakiety -g"), icon: "shippingbox",
                                items: npmPkgs,
                                rollbackCaption: tr("Bez automatycznego cofnięcia — npm nie zachowuje poprzednich wersji pakietów."),
                                selected: $scan.selected, inspectedKey: scan.inspectedKey,
                                onIgnore: scan.ignoreItem, onPin: requestPin, onSkip: scan.skipItem,
                                onInspect: { scan.inspectedKey = $0.key }
                            )
                        }
                        // Group manual updates by INSTALL ORIGIN (same axis the Inventory
                        // window labels), not by update source. A self-updating Homebrew
                        // cask (Docker, Postman, ChatGPT…) stays under "Homebrew Casks" so
                        // both windows agree it's Brew — only genuinely non-package-manager
                        // apps land under "Ręcznie zainstalowane".
                        let manualGroups = UpdatePlanner.groupManual(visibleManual)
                        let brewManual = updateFilter.isSecurityOnly ? manualGroups.brew.filter(scan.isSecurityApp) : manualGroups.brew
                        if !brewManual.isEmpty && updateFilter != .cli {
                            ManualUpdateSection(
                                items: brewManual,
                                busyToken: scan.manualBusy,
                                onInstall: { token in Task { await scan.installManual(token: token) } },
                                title: tr("Homebrew Casks"),
                                icon: "app.gift",
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
                                icon: "sparkle",
                                caption: tr("Bez automatycznego cofnięcia — poprzednią wersję pobierzesz od wydawcy."),
                                inspectedKey: scan.inspectedKey,
                                onIgnore: scan.ignoreManual,
                                onPin: requestPinManual,
                                onSkip: scan.skipManual,
                                onInspect: { scan.inspectedKey = "m:" + $0.path.path }
                            )
                        }
                        if !scan.restartCandidates.isEmpty {
                            RestartSection(
                                candidates: scan.restartCandidates,
                                busyProcess: scan.restartBusy,
                                onRestart: { info in Task { await scan.restartApp(info) } }
                            )
                        }
                        if scan.showLog {
                            BrewLogPanel(lines: scan.brewLog) { scan.showLog = false }
                        }
                    }
                    .padding(WegaLayout.listGutter)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        } else {
            EmptyHero(
                pose: .idle,
                title: tr("Nic w tej kategorii"),
                message: tr("W tej kategorii nie ma teraz aktualizacji. Przełącz kategorię w panelu bocznym."),
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
    @ViewBuilder
    private var planPreview: some View {
        if !updateTargets.isEmpty {
            WegaDisclosure(isExpanded: $scan.showPlanPreview) {
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
                .padding(.top, 8)
            } label: {
                Text(tr("Pokaż, co dokładnie zrobię"))
                    .font(.wega(.callout, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .onChange(of: scan.showPlanPreview) { _, expanded in
                if expanded { Task { await scan.probeDownloadSizes(targetKeys: updateTargetKeys) } }
            }
        }
    }

    /// M3(b) — offers the cleanup that "check for updates" used to perform behind the
    /// user's back. Names every cask it would remove; the scan already excluded them from
    /// the list above, so nothing here is load-bearing for the count.
    @ViewBuilder
    private var staleCaskCard: some View {
        if !scan.staleCasks.isEmpty {
            WegaCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "trash").foregroundStyle(Color.wegaToffee)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trf("%@ casków bez aplikacji", "\(scan.staleCasks.count)"))
                            .font(.wega(.callout, weight: .semibold))
                        Text(trf("Homebrew wciąż śledzi: %@. Aplikacji nie ma na dysku — możesz je wyrejestrować.", "\(scan.staleCasks.joined(separator: ", "))"))
                            .font(.wega(.subheadline)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(tr("Nie teraz")) { scan.dismissStaleCasks() }
                        .disabled(scan.cleaningStaleCasks)
                    Button(tr("Wyrejestruj")) { Task { await scan.cleanUpStaleCasks() } }
                        .disabled(scan.cleaningStaleCasks)
                }
                .padding(12)
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
            WegaCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(Color.wegaDanger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Bez weryfikacji sumy kontrolnej"))
                            .font(.wega(.callout, weight: .semibold))
                        Text(trf("Homebrew zainstaluje bez sprawdzenia sumy: %@", "\(noCheck.map(\.name).joined(separator: ", "))"))
                            .font(.wega(.subheadline)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(12)
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
                Label(tr("suma sprawdzana"), systemImage: "checkmark.seal")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.wegaSuccess)
                    .help(tr("suma sprawdzana"))
            } else {
                Label(tr("bez weryfikacji sumy"), systemImage: "exclamationmark.shield")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.wegaDanger)
                    .help(tr("bez weryfikacji sumy"))
            }
            if protection == .protected {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(Color.wegaSuccess)
                    .help(tr("Chronione automatycznym cofnięciem"))
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
    }
}
