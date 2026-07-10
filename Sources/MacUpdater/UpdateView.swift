import SwiftUI
import MacUpdaterCore

/// The update currently shown in the inspector pane — either a package-manager-tracked
/// item (brew/mas/npm) or a manually-checked app. Module-internal (not `private`) so
/// `InspectorPane`, in its own file, can render it.
enum InspectedUpdate: Equatable {
    case outdated(OutdatedItem, iconPath: URL?)
    case manual(ManualOutdatedApp)
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

    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var policies: UpdatePolicyStore
    /// Scan results and the tasks that produce them live above the language re-key,
    /// so switching language mid-scan neither loses the list nor orphans the task.
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.openSettings) private var openSettings

    /// Purely transient: a modal that no background task writes to, so it may die
    /// with the view tree.
    @State private var pinTarget: PinRequest? = nil

    private var allItems: [OutdatedItem] { scan.allItems }
    private var visibleManual: [ManualOutdatedApp] { scan.visibleManual }

    var body: some View {
        content
            .sheet(item: $pinTarget) { req in
                PinVersionSheet(request: req) { version in
                    policies.pin(key: req.key, name: req.name, version: version)
                }
            }
            // Switching the sidebar category re-filters the list but not the inspector's
            // resolver, so a selection made in one category would otherwise keep showing in
            // the pane after switching away from it. Clear it so the detail pane never
            // describes an item that's no longer in the visible list.
            .onChange(of: updateFilter) { scan.inspectedKey = nil }
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
                    categoryCounts: onCategoryCounts
                ))
                // M2 — put the previous result on screen before doing anything else. It is
                // a no-op after the first appearance and whenever a scan has already run.
                scan.restoreLastScan()
                scan.replayLastScan()
            }
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
            message: tr("Wega zajrzy do Homebrew oraz Mac App Store i powie, co warto odświeżyć."),
            action: AnyView(
                Button { scan.startCheck() } label: {
                    Label(tr("Sprawdź aktualizacje"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
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
            HStack(spacing: 10) {
                ProgressView(value: scan.progress?.fractionCompleted ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Color.wegaHoney)
                if scan.progress?.isCancellable == true {
                    Button(tr("Anuluj")) { scan.cancelScan() }
                        .controlSize(.small)
                }
            }
            if case .running(let phase) = scan.progress {
                Text(phase.commandLabel)
                    .font(.system(size: 11, design: .monospaced))
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
            .padding(.top, 16)
        }
        .padding(24)
    }

    // MARK: Results
    private var resultsView: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 18, weight: .semibold))
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
                            Text("brew + mas").font(.system(size: 11, design: .monospaced))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(freshness.needsExplicitTimestamp ? AnyShapeStyle(Color.wegaToffee) : AnyShapeStyle(.tertiary))
                    }
                }
                Spacer()
                Button { scan.startCheck() } label: {
                    Label(tr("Sprawdź ponownie"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(scan.updating || scan.status == .checking)

                if !allItems.isEmpty {
                    Button { Task { await scan.runUpdate() } } label: {
                        if scan.updating {
                            ProgressView().controlSize(.small)
                        } else if scan.selected.isEmpty {
                            Label(trf("Zaktualizuj wszystkie (%@)", "\(allItems.count)"), systemImage: "arrow.down.circle.fill")
                        } else {
                            Label(trf("Zaktualizuj wybrane (%@)", "\(scan.selected.count)"), systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoney)
                    .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                    .disabled(scan.updating)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let b = scan.banner {
                BannerView(
                    data: b,
                    onAction: { action in
                        switch action {
                        case .openLogs: onNavigate?(.logs)
                        case .openSettings:
                            openSettings()
                        }
                    },
                    onClose: { scan.dismissBanner() }
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            staleCaskCard

            HStack(spacing: 0) {
                listColumn
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Divider()
                InspectorPane(
                    update: scan.inspectedUpdate,
                    busyToken: scan.manualBusy,
                    onInstall: { token in Task { await scan.installManual(token: token) } },
                    caskDownloads: scan.caskDownloads
                )
                    .frame(width: 340)
            }
        }
    }

    @ViewBuilder
    private var listColumn: some View {
        if allItems.isEmpty && visibleManual.isEmpty && scan.restartCandidates.isEmpty {
            EmptyHero(pose: .sleep, title: tr("Wszystko aktualne"), message: tr("Wega się zdrzemnie. Zajrzymy znowu za jakiś czas."), compact: true, playful: true)
        } else if filterHasContent(updateFilter) || !scan.restartCandidates.isEmpty {
            VStack(spacing: 0) {
                // Select-all row
                HStack(spacing: 10) {
                    Image(systemName: selectAllSymbol)
                        .foregroundStyle(scan.selected.isEmpty ? .secondary : Color.wegaHoney)
                        .font(.system(size: 16))
                        .onTapGesture { scan.toggleAll() }
                        .accessibilityLabel(tr("Zaznacz wszystko"))
                        .accessibilityAddTraits(.isButton)
                    Text(scan.selected.isEmpty ? tr("Zaznacz wszystko") : trf("%@ z %@ zaznaczonych", "\(scan.selected.count)", "\(allItems.count)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        let formulae = allItems.filter { $0.kind == .formula }
                        let casks    = allItems.filter { $0.kind == .cask }
                        let store    = allItems.filter { $0.kind == .appStore }
                        let npmPkgs  = allItems.filter { $0.kind == .npm }
                        if !formulae.isEmpty && updateFilter.allowsCli { UpdateSection(title: tr("Homebrew Formulae"), subtitle: tr("narzędzia CLI"),  icon: "terminal",  items: formulae, selected: $scan.selected, inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreItem, onPin: requestPin, onInspect: { scan.inspectedKey = $0.key }) }
                        if !casks.isEmpty && updateFilter.allowsApps {
                            UpdateSection(title: tr("Homebrew Casks"), subtitle: tr("aplikacje .app"), icon: "app.gift", items: casks, iconPaths: scan.caskIconPaths, rollbackProtection: scan.caskProtection, selected: $scan.selected, inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreItem, onPin: requestPin, onInspect: { scan.inspectedKey = $0.key })
                            caskTransparencyNote(casks: casks)
                        }
                        if !store.isEmpty && updateFilter.allowsApps    { UpdateSection(title: tr("Mac App Store"),     subtitle: tr("via mas-cli"),      icon: "bag",      items: store,    selected: $scan.selected, inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreItem, onPin: requestPin, onInspect: { scan.inspectedKey = $0.key }) }
                        if !npmPkgs.isEmpty && updateFilter.allowsCli  { UpdateSection(title: tr("npm globalne"),      subtitle: tr("pakiety -g"),       icon: "shippingbox", items: npmPkgs, selected: $scan.selected, inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreItem, onPin: requestPin, onInspect: { scan.inspectedKey = $0.key }) }
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
                                inspectedKey: scan.inspectedKey,
                                onIgnore: scan.ignoreManual,
                                onPin: requestPinManual,
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
                    .padding(16)
                }
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
                            .font(.system(size: 12, weight: .semibold))
                        Text(trf("Homebrew wciąż śledzi: %@. Aplikacji nie ma na dysku — możesz je wyrejestrować.", "\(scan.staleCasks.joined(separator: ", "))"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
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

    private var selectAllSymbol: String {
        switch UpdatePlanner.selectAllState(selectedCount: scan.selected.count, totalCount: allItems.count) {
        case .none:    return "square"
        case .all:     return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
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
                            .font(.system(size: 12, weight: .semibold))
                        Text(trf("Homebrew zainstaluje bez sprawdzenia sumy: %@", "\(noCheck.map(\.name).joined(separator: ", "))"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
    }
}
