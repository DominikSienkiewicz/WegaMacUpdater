import SwiftUI
import AppKit
import MacUpdaterCore

struct UninstallView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel
    /// The Settings window hosts the helper card that turns Wega's helper on.
    @Environment(\.openSettings) private var openSettings

    @State private var apps:          [ApplicationInfo] = []
    @State private var protections:    [String: UninstallProtection] = [:]
    @State private var selected:       Set<String>       = []
    @State private var search:         String            = ""
    @StateObject private var operations = UninstallCoordinator()
    @State private var showDialog:     Bool              = false
    /// UX-01: the exact visible installations named by the confirmation. Execution
    /// consumes this frozen collection instead of resolving selection through a filter
    /// for a second time after consent.
    @State private var pendingUninstallTargets: [ApplicationInfo] = []
    /// REL-14: whether the scan behind `pendingUninstallTargets` was incomplete, frozen
    /// at confirmation time so the dialog can warn that the target list may be partial.
    @State private var pendingScanIncomplete: Bool = false
    /// UX-13: `~/Library` leftovers found for the non-brew targets, planned via
    /// `MigrationPlanner` before the confirm sheet opens so it can offer them as checkboxes.
    @State private var pendingLeftoverGroups: [LeftoverGroup] = []
    /// UX-13: which leftover paths the user has ticked for the Trash. Defaults to every
    /// found item; the user opts individual files out.
    @State private var selectedLeftovers: Set<String> = []
    /// The running state of `pendingUninstallTargets`, computed when the sheet opens.
    @State private var pendingRunningStates: [String: RunningApplicationResolution] = [:]
    @State private var forceQuitApps: [ApplicationInfo] = []
    @State private var showForceQuit: Bool = false
    @State private var forceQuitAnswer: CheckedContinuation<UninstallForceQuitChoice, Never>?
    /// REL-14: why the last scan could not read a source. Kept apart from `result`, so a run's
    /// result never hides a scan error that is already on screen.
    @State private var scanError:      String?
    /// The apps the last run did not remove — summary line and rows — kept together so a
    /// refresh never leaves a row or its button without its explanation.
    @State private var result:         UninstallResultReport?
    /// The route each non-brew target would take, computed when the sheet opens.
    @State private var pendingRoutes: [String: UninstallRouteDecision] = [:]
    /// REL-14: the last scan failed to read one or more sources. Distinguishes an empty
    /// machine from a failed scan and drives the incomplete-data warning before uninstall.
    @State private var scanFailed:     Bool              = false
    @State private var banner:         BannerData?

    private var isLoading: Bool { operations.isScanning }
    private var isUninstalling: Bool { operations.isUninstalling || operations.isQuitting }

    /// REL-14: resolves the list body between loading, a failed scan, an empty machine
    /// and populated results, so a scan failure is never shown as "no apps found".
    private var listState: UninstallListState {
        UninstallListState.resolve(isLoading: isLoading, appsEmpty: apps.isEmpty, scanFailed: scanFailed)
    }

    private var filtered: [ApplicationInfo] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// REL-16: uninstalling is destructive, so a copy the user cannot tell apart
    /// from another must not be offered as a bare name — these rows show where
    /// the copy lives.
    private var ambiguousBundleIds: Set<String> {
        InstallationInventory.ambiguousBundleIdentifiers(apps)
    }

    private func showsLocation(_ app: ApplicationInfo) -> Bool {
        app.bundleIdentifier.map(ambiguousBundleIds.contains) ?? false
    }

    private var targets: [ApplicationInfo] {
        UninstallSelection.targets(filtered: filtered, selected: selected, protections: protections)
    }

    private var selectableCount: Int {
        UninstallSelection.selectable(filtered, protections: protections).count
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Odinstaluj aplikacje")).font(.wega(.title2, weight: .semibold))
                        Text(tr("Brew casks → brew uninstall  ·  pozostałe → Kosz"))
                            .font(.wega(.subheadline, monospaced: true))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { Task { await refresh() } } label: {
                        Label(tr("Odśwież"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading || isUninstalling)

                    Button {
                        Task { await presentUninstallDialog() }
                    } label: {
                        if isUninstalling { ProgressView().controlSize(.small) }
                        else { Label(targets.isEmpty ? tr("Odinstaluj") : trf("Odinstaluj (%@)", "\(targets.count)"), systemImage: "trash") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaDanger)
                    .disabled(targets.isEmpty || isUninstalling)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let scanError {
                    ErrorBanner(message: scanError).padding(.horizontal, 16).padding(.bottom, 8)
                }
                if let result {
                    UninstallResultList(report: result, onAction: perform) { self.result = nil }
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
                if let b = banner {
                    BannerView(data: b) { banner = nil }.padding(.horizontal, 16).padding(.bottom, 8)
                }

                // Select-all row
                WegaCard(padded: false) {
                    HStack(spacing: 10) {
                        Button(action: toggleAll) {
                            Image(systemName: selectAllSymbol)
                                .foregroundStyle(targets.isEmpty ? .secondary : Color.wegaHoney)
                                .font(.wega(.title3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Zaznacz wszystko"))
                        .accessibilityValue(
                            trf("%@ z %@ zaznaczonych", "\(targets.count)", "\(selectableCount)")
                        )
                        Text(targets.isEmpty
                             ? trf("%@ aplikacji", "\(filtered.count)")
                             : trf("%@ zaznaczonych z %@", "\(targets.count)", "\(selectableCount)"))
                            .font(.wega(.callout))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(tr("NAZWA · WERSJA · ŹRÓDŁO"))
                            .font(.wega(.footnote, monospaced: true))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // List
                if isLoading {
                    Spacer()
                    SniffingScene(
                        caption: tr("Skanowanie aplikacji…"),
                        thoughts: [
                            tr("Co tu można wynieść?"),
                            tr("Sniff sniff… kandydat"),
                            tr("Łapię zapach Library/Caches"),
                            tr("Mhm, czy używasz tego jeszcze?"),
                            tr("Bundle ID… znajomy"),
                            tr("Kto zostawił tę apkę?"),
                            tr("Czy brew o tym wie?"),
                            tr("Mhm… stare receipty"),
                            tr("Pachnie zajętym miejscem"),
                            tr("Aport albo zostaw?")
                        ],
                        wegaSize: 110,
                        height: 150
                    )
                    .padding(.vertical, 12)
                    Spacer()
                } else if listState == .scanFailed {
                    // REL-14: a failed scan must not read as "no apps" — say the scan failed.
                    EmptyHero(
                        pose: .idle,
                        title: tr("Skan się nie powiódł"),
                        message: tr("Nie udało się odczytać listy zainstalowanych aplikacji. Spróbuj ponownie.")
                    )
                } else if listState == .empty {
                    EmptyHero(
                        pose: .idle,
                        title: tr("Brak aplikacji"),
                        message: tr("Nie znaleziono żadnych zainstalowanych aplikacji.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { app in
                                let protection = protections[app.id]
                                let isSelected = protection == nil && selected.contains(app.id)
                                let reason = protection.map(UninstallProtectionPresentation.protectionReason)
                                // UX-02 — a real `Toggle`, so the row announces itself as a
                                // checkbox with a state rather than as a button with a value.
                                Toggle(isOn: selectionToggleBinding(isOn: isSelected) { toggle(app.id) }) {
                                    HStack(spacing: 12) {
                                        AppIcon(path: app.path, size: 26)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(app.name).font(.body.weight(.medium))
                                            if showsLocation(app) {
                                                Text(app.locationLabel)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(Color.wegaDanger.opacity(0.85))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            if let token = app.caskToken {
                                                Text(token)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.tertiary)
                                            }
                                            if let reason {
                                                Text(reason)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        if let v = app.version {
                                            Text(v)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.tertiary)
                                        }
                                        sourceLabel(app)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .toggleStyle(WegaCheckboxToggleStyle())
                                .disabled(protection != nil)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(isSelected ? Color.wegaDanger.opacity(0.06) : Color.clear)
                                .accessibilityLabel(selectionAccessibilityLabel(for: app, showsLocation: showsLocation(app), protectionReason: reason))
                                // UX-11d: right-click gives the row the actions it otherwise
                                // lacked — reveal it in Finder, copy its path, or toggle its
                                // removal selection.
                                .contextMenu { rowContextMenu(for: app, isSelected: isSelected, canToggle: protection == nil) }

                                Divider().opacity(0.4).padding(.leading, 54)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

        }
        // UX-11c — native `.searchable` in place of the header's hand-built search field.
        .searchable(text: $search, prompt: tr("Szukaj…"))
        .sheet(isPresented: $showDialog) {
            UninstallDialog(
                targets:     pendingUninstallTargets,
                ambiguities: InstallationInventory.ambiguousBrewUninstalls(
                    selected: pendingUninstallTargets,
                    among: apps
                ),
                scanIncomplete: pendingScanIncomplete,
                leftoverGroups: pendingLeftoverGroups,
                runningStates: pendingRunningStates,
                routes: pendingRoutes,
                isRefreshing: operations.isScanning,
                selectedLeftovers: $selectedLeftovers,
                onCancel: cancelUninstall,
                onConfirm: confirmUninstall
            )
        }
        .sheet(
            isPresented: $showForceQuit,
            onDismiss: { answerForceQuit(.cancel) },
            content: { UninstallForceQuitSheet(apps: forceQuitApps, onChoice: answerForceQuit) }
        )
        .onChange(of: search) { _, _ in
            selected.formIntersection(filtered.map(\.id))
        }
        .task { await scan() }
    }

    private func perform(_ action: UninstallResultAction) {
        switch action {
        case .showInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openAppManagementSettings:
            NSWorkspace.shared.open(AppManagementSettings.paneURL)
        case .openHelperSettings:
            openSettings()
        }
    }

    /// UX-11d: the row's right-click menu. Its contents live in `AppRowContextMenu` so the
    /// wording and ordering are unit-testable; this renders them and routes each selection.
    @ViewBuilder
    private func rowContextMenu(for app: ApplicationInfo, isSelected: Bool, canToggle: Bool) -> some View {
        ForEach(AppRowContextMenu.items(isSelected: isSelected, canToggle: canToggle)) { item in
            Button {
                performRowAction(item.action, for: app)
            } label: {
                Label(item.title, systemImage: item.systemImage)
            }
        }
    }

    @ViewBuilder
    private func sourceLabel(_ app: ApplicationInfo) -> some View {
        if app.isManagedByBrew {
            WegaBadge(label: "brew", variant: .brew)
        } else if app.isManagedByMas {
            WegaBadge(label: "mas", variant: .appStore)
        } else {
            WegaBadge(label: "manual", variant: .manual)
        }
    }

    private var selectAllSymbol: String {
        UninstallSelection.selectAllSymbol(filtered: filtered, selected: selected, protections: protections)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// UX-11d: routes a row context-menu selection to its side effect. The menu contents
    /// live in `AppRowContextMenu`; this keeps the row a thin wiring layer over them.
    private func performRowAction(_ action: AppRowContextMenuAction, for app: ApplicationInfo) {
        switch action {
        case .toggleSelection:
            toggle(app.id)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([app.path])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AppRowContextMenu.pathToCopy(for: app), forType: .string)
        }
    }

    private func toggleAll() {
        let selectableIds = UninstallSelection.selectAll(filtered: filtered, protections: protections)
        if Set(targets.map(\.id)) == selectableIds { selected.removeAll() }
        else { selected = selectableIds }
    }

    /// UX-13: freezes the confirmation targets (UX-01), then plans their `~/Library`
    /// leftovers via the coordinator so the sheet opens with the checkbox list ready.
    private func presentUninstallDialog() async {
        let targets = self.targets
        guard !targets.isEmpty, !isUninstalling else { return }
        pendingUninstallTargets = targets
        pendingScanIncomplete = scanFailed
        pendingRoutes = operations.routes(for: targets)
        // A blocked target is not attempted: it is neither asked to quit nor offers leftovers.
        let attempted = UninstallQuitFlow.partition(targets: targets, routes: pendingRoutes).attempt
        pendingRunningStates = operations.runningStates(for: attempted)
        let groups = await operations.scanLeftovers(for: attempted)
        pendingLeftoverGroups = groups
        selectedLeftovers = Set(groups.flatMap { $0.items.map(\.path) })
        showDialog = true
    }

    private func cancelUninstall() {
        showDialog = false
        pendingUninstallTargets = []
        pendingScanIncomplete = false
        pendingLeftoverGroups = []
        pendingRunningStates = [:]
        pendingRoutes = [:]
        selectedLeftovers = []
    }

    private func answerForceQuit(_ choice: UninstallForceQuitChoice) {
        showForceQuit = false
        forceQuitAnswer?.resume(returning: choice)
        forceQuitAnswer = nil
    }

    private func askForceQuit(_ apps: [ApplicationInfo]) async -> UninstallForceQuitChoice {
        await withCheckedContinuation { continuation in
            forceQuitApps = apps
            forceQuitAnswer = continuation
            showForceQuit = true
        }
    }

    private func quitThenUninstall(
        targets: [ApplicationInfo],
        routes: [String: UninstallRouteDecision],
        zap: Bool,
        leftovers: [LeftoverGroup]
    ) async {
        defer { operations.endQuitPhase() }
        guard let plan = await operations.runQuitPhase(targets: targets, routes: routes, askForceQuit: askForceQuit)
        else { return }
        await uninstall(targets: plan.remove, zap: zap, leftovers: leftovers, skipped: plan.skipped, reported: targets)
    }

    private func confirmUninstall(zap: Bool) {
        guard operations.beginQuitPhase() else { return }
        let targets = pendingUninstallTargets
        let routes = pendingRoutes
        let leftovers = pendingLeftoverGroups.compactMap { group -> LeftoverGroup? in
            let consented = group.items.filter { selectedLeftovers.contains($0.path) }
            return consented.isEmpty ? nil : LeftoverGroup(app: group.app, items: consented)
        }
        showDialog = false
        pendingUninstallTargets = []
        pendingScanIncomplete = false
        pendingLeftoverGroups = []
        pendingRunningStates = [:]
        pendingRoutes = [:]
        selectedLeftovers = []
        Task { await quitThenUninstall(targets: targets, routes: routes, zap: zap, leftovers: leftovers) }
    }

    /// A refresh starts over: the last run's result goes as a whole, summary and rows together.
    private func refresh() async {
        result = nil
        banner = nil
        await scan()
    }

    private func scan() async {
        guard let scan = await operations.scan(using: model.brewService) else { return }
        apps = scan.apps
        protections = scan.protections
        scanFailed = scan.scanFailed
        scanError = scan.failures.scanErrorMessage
    }

    /// - Parameter reported: every confirmed target, in confirmation order; each one ends in
    ///   exactly one result, whether removed, skipped before removal, or blocked.
    private func uninstall(
        targets: [ApplicationInfo],
        zap: Bool,
        leftovers: [LeftoverGroup],
        skipped: [String: UninstallTargetResult],
        reported reportedApps: [ApplicationInfo]
    ) async {
        guard !targets.isEmpty else {
            show(UninstallResultPresentation.report(
                results: skipped, apps: reportedApps, leftoversTrashed: 0, leftoversFailed: 0, requestedZap: zap
            ))
            return
        }
        // REL-06 — `brew uninstall --cask` (with `--zap` it also deletes preferences and
        // Application Support) rewrites the Caskroom, and `UpgradeMutex` only covers upgrades.
        // Without a ticket a quit here ends the process between the Caskroom entry and the
        // bundle, which is the half-removed state the guard exists to prevent.
        let ticket = MutationGuard.shared.begin(trf("dezinstalacja %@ aplikacji", "\(targets.count)"))
        defer { MutationGuard.shared.end(ticket) }

        banner = nil; result = nil
        onWegaState?(WegaState(pose: .sniff, line: tr("Aport! Zabieram to z dysku…")))

        let outcome = await operations.uninstall(
            targets: targets,
            zap: zap,
            leftovers: leftovers,
            skipped: skipped,
            using: model.brewService
        )
        let succeeded = Set(targets.map(\.id).filter { outcome.results[$0]?.isRemoved == true })
        selected.subtract(succeeded)
        await scan()

        let report = UninstallResultPresentation.report(
            results: outcome.results,
            apps: reportedApps,
            leftoversTrashed: outcome.leftoversTrashed,
            leftoversFailed: outcome.leftoversFailed,
            requestedZap: zap
        )
        if !succeeded.isEmpty {
            onWegaState?(WegaState(pose: .happy, line: trf("Załatwione — %@ mniej na dysku.", "\(succeeded.count)")))
        }
        show(report)
    }

    /// The success banner names what was removed; everything else stays together in `result`.
    private func show(_ report: UninstallResultReport) {
        banner = report.banner
        result = report.summary == nil && report.rows.isEmpty ? nil : report
    }
}

// MARK: - Native uninstall sheet

struct UninstallDialog: View {
    let targets: [ApplicationInfo]
    /// REL-16: casks whose application is installed in more than one place — see
    /// `InstallationInventory.ambiguousBrewUninstalls`.
    let ambiguities: [AmbiguousBrewUninstall]
    /// REL-14: the scan behind these targets failed to read one or more sources, so the
    /// list may be missing installations. The dialog warns before the destructive action.
    var scanIncomplete: Bool = false
    /// UX-13: the `~/Library` leftovers planned for the non-brew targets, presented as
    /// checkboxes so the user reviews exactly what "app + leftovers" removes.
    var leftoverGroups: [LeftoverGroup] = []
    /// Which targets are running right now, so the sheet can say Wega will ask them to quit.
    var runningStates: [String: RunningApplicationResolution] = [:]
    /// What will happen to each non-brew target: Trash, or why it cannot be removed.
    var routes: [String: UninstallRouteDecision] = [:]
    /// The list is being rescanned; confirming has to wait until it finishes.
    var isRefreshing: Bool = false
    /// UX-13: the leftover paths the user has ticked for the Trash. Bound to the caller so
    /// the confirmed selection survives the sheet dismissal.
    @Binding var selectedLeftovers: Set<String>
    let onCancel:   () -> Void
    let onConfirm:  (Bool) -> Void

    init(
        targets: [ApplicationInfo],
        ambiguities: [AmbiguousBrewUninstall],
        scanIncomplete: Bool = false,
        leftoverGroups: [LeftoverGroup] = [],
        runningStates: [String: RunningApplicationResolution] = [:],
        routes: [String: UninstallRouteDecision] = [:],
        isRefreshing: Bool = false,
        selectedLeftovers: Binding<Set<String>> = .constant([]),
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Bool) -> Void
    ) {
        self.targets = targets
        self.ambiguities = ambiguities
        self.scanIncomplete = scanIncomplete
        self.leftoverGroups = leftoverGroups
        self.runningStates = runningStates
        self.routes = routes
        self.isRefreshing = isRefreshing
        self._selectedLeftovers = selectedLeftovers
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    /// M3(e) — the irreversible option is never the default. `--zap` also deletes
    /// preferences, caches and Application Support; the user opts into that deliberately.
    @State private var zapMode: Bool = false

    /// Why the confirm button is unavailable, or `nil` when it can be pressed. A refresh holds
    /// the coordinator, and confirming then would do nothing.
    static func confirmUnavailableNote(isRefreshing: Bool) -> String? {
        isRefreshing ? tr("Lista aplikacji się odświeża — poczekaj, aż skończy.") : nil
    }

    /// A blocked target is never asked to quit, so it gets no running note.
    static func runningNote(for state: RunningApplicationResolution?, route: UninstallRouteDecision?) -> String? {
        if case .blocked = route { return nil }
        return switch state {
        case .running: tr("Uruchomiona — Wega poprosi o jej zamknięcie")
        case .ambiguousBundleIdentifier: tr("Nie da się wskazać jej procesu — zostanie pominięta")
        case .notRunning, nil: nil
        }
    }

    static func routeNote(for route: UninstallRouteDecision?) -> String? {
        switch route {
        case .userTrash: tr("trafi do Kosza")
        case .helper: tr("pomocnik Wega usunie ją bez hasła")
        case .blocked(let block): UninstallResultPresentation.blockReason(block)
        case nil: nil
        }
    }

    private var counts: UninstallDialogCounts { UninstallDialogCounts(targets: targets, routes: routes) }
    private var brewCount: Int { counts.brew }
    private var trashCount: Int { counts.trash }
    private var blockedCount: Int { counts.blocked }
    private var totalCount: Int { targets.count }
    private var hasMixed: Bool { brewCount > 0 && trashCount > 0 }
    private var hasNonBrew: Bool { trashCount > 0 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.wegaDanger.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "trash")
                        .foregroundStyle(Color.wegaDanger)
                        .font(.wega(.title2))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(trf("Odinstalować %@ %@?", "\(totalCount)", totalCount == 1 ? tr("aplikację") : tr("aplikacji")))
                        .font(.wega(.title3, weight: .semibold))
                    if hasMixed {
                        Text(trf("%@ przez brew · %@ do Kosza", "\(brewCount)", "\(trashCount)"))
                            .font(.wega(.callout))
                            .foregroundStyle(.secondary)
                    } else if hasNonBrew {
                        Text(tr("Aplikacje trafią do Kosza"))
                            .font(.wega(.callout))
                            .foregroundStyle(.secondary)
                    } else if blockedCount == 0 {
                        Text(tr("Wybierz, co zostawić"))
                            .font(.wega(.callout))
                            .foregroundStyle(.secondary)
                    }
                    if blockedCount > 0 {
                        Text(trf("%@ nie da się usunąć — szczegóły poniżej", "\(blockedCount)"))
                            .font(.wega(.callout))
                            .foregroundStyle(Color.wegaDanger)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 0) {
                    if scanIncomplete {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.wegaDanger)
                                .font(.wega(.body))
                            Text(tr("Skan aplikacji był niekompletny — lista celów może nie zawierać wszystkich instalacji. Zweryfikuj przed usunięciem."))
                                .font(.wega(.subheadline))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(
                            Color.wegaDanger.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.wegaDanger.opacity(0.28), lineWidth: 1)
                        )
                        .padding(.horizontal, 22)
                        .padding(.bottom, 12)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Dokładne cele"))
                            .font(.wega(.callout, weight: .semibold))
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(targets) { app in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.wega(.callout, weight: .medium))
                                    Text(app.path.path)
                                        .font(.wega(.footnote, monospaced: true))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    if let routeNote = Self.routeNote(for: routes[app.id]) {
                                        Text(routeNote)
                                            .font(.wega(.footnote))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let note = Self.runningNote(for: runningStates[app.id], route: routes[app.id]) {
                                        Text(note)
                                            .font(.wega(.footnote))
                                            .foregroundStyle(Color.wegaDanger)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        Color(NSColor.controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)

                    // Options — only shown when brew casks are selected
                    if brewCount > 0 {
                        VStack(spacing: 8) {
                            UninstallOption(
                                title:       tr("Tylko aplikacja"),
                                subtitle:    tr("Usuwa plik .app. Preferencje i cache zostają w ~/Library."),
                                command:     "brew uninstall",
                                recommended: true,
                                isSelected:  !zapMode,
                                onSelect:    { zapMode = false }
                            )
                            UninstallOption(
                                title:       tr("Aplikacja + resztki"),
                                subtitle:    tr("Zabiera też pliki w ~/Library/Preferences, Caches i Application Support. Tego nie da się cofnąć."),
                                command:     "brew uninstall --zap",
                                recommended: false,
                                isSelected:  zapMode,
                                onSelect:    { zapMode = true }
                            )
                        }
                        .padding(.horizontal, 22)
                    }

                    if !ambiguities.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(ambiguities) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.wegaDanger)
                                        .font(.wega(.body))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tr("Homebrew usunie swoją kopię"))
                                            .font(.wega(.callout, weight: .semibold))
                                        Text(trf(
                                            "%@ jest zainstalowany w %@ miejscach: %@. Homebrew usunie kopię, którą sam zarządza (brew uninstall %@) — niekoniecznie tę zaznaczoną.",
                                            "\(item.appName)",
                                            "\(item.locations.count)",
                                            "\(item.locations.joined(separator: ", "))",
                                            "\(item.caskToken)"
                                        ))
                                        .font(.wega(.subheadline))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            Color.wegaDanger.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.wegaDanger.opacity(0.28), lineWidth: 1)
                        )
                        .padding(.horizontal, 22)
                        .padding(.top, brewCount > 0 ? 12 : 0)
                    }

                    if hasNonBrew {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Color.wegaInfo)
                                .font(.wega(.body))
                            Text(trf("%@ %@ przez brew — trafi do Kosza.", "\(trashCount)", trashCount == 1 ? tr("aplikacja nie jest zarządzana") : tr("aplikacji nie jest zarządzanych")))
                                .font(.wega(.callout))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, brewCount > 0 ? 10 : 0)
                    }

                    // UX-13: "app + leftovers" for non-brew apps — the same `~/Library`
                    // items brew would clear with `--zap`, presented so the user reviews
                    // and consents before they go to the (recoverable) Trash.
                    if !leftoverGroups.isEmpty {
                        UninstallLeftoverSelection(
                            groups: leftoverGroups,
                            selected: $selectedLeftovers
                        )
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                    }
                }
            }
            .frame(minHeight: 240, idealHeight: 480, maxHeight: 560)

            // Footer buttons
            HStack(spacing: 8) {
                if let note = Self.confirmUnavailableNote(isRefreshing: isRefreshing) {
                    Text(note)
                        .font(.wega(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(tr("Anuluj"), role: .cancel) {
                    UninstallDialogKeyboardBehavior.perform(
                        .cancel,
                        zapMode: zapMode,
                        onCancel: onCancel,
                        onConfirm: onConfirm
                    )
                }
                .keyboardShortcut(.cancelAction)
                if counts.removesNothing {
                    // Every target is blocked: confirming removes and quits nothing, it only
                    // reports why, so the button is not dressed as destructive.
                    Button(confirmLabel) { confirm() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isRefreshing)
                } else {
                    Button(confirmLabel, role: .destructive) { confirm() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.wegaDanger)
                        .disabled(isRefreshing)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .background(Color.wegaRecessedSurface)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.wegaHairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 12)
        .frame(width: 480)
    }

    private func confirm() {
        UninstallDialogKeyboardBehavior.perform(.confirm, zapMode: zapMode, onCancel: onCancel, onConfirm: onConfirm)
    }

    private var confirmLabel: String {
        if brewCount > 0 {
            return zapMode ? tr("Usuń razem z resztkami") : tr("Usuń tylko aplikację")
        }
        return counts.promisesTrash ? tr("Przenieś do Kosza") : tr("Pokaż, czego nie usunięto")
    }
}

struct UninstallOption: View {
    let title:       String
    let subtitle:    String
    let command:     String
    let recommended: Bool
    let isSelected:  Bool
    let onSelect:    () -> Void

    var body: some View {
        let semantics = UninstallOptionAccessibilitySemantics(
            title: title,
            isSelected: isSelected
        )
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.wegaHoneyFill : Color(NSColor.controlBackgroundColor))
                        .frame(width: 16, height: 16)
                    if isSelected {
                        Circle().fill(Color.wegaInk).frame(width: 6, height: 6)
                    }
                }
                .overlay(Circle().stroke(isSelected ? Color.wegaHoney : Color.wegaHairline, lineWidth: 1))
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.wega(.headline))
                        if recommended {
                            Text(tr("zalecane"))
                                .font(.wega(.footnote, weight: .medium, monospaced: true))
                                .foregroundStyle(Color.wegaHoney)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.wegaHoney.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.wegaHoney.opacity(0.25), lineWidth: 1))
                        }
                    }
                    Text(subtitle)
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Text("$ \(command)")
                        .font(.wega(.footnote, monospaced: true))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                Spacer()
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(semantics.label)
        .accessibilityValue(semantics.value)
        .accessibilityAddTraits(semantics.isSelected ? .isSelected : [])
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.wegaHoney.opacity(0.06) : Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.wegaHoney.opacity(0.32) : Color.wegaHairline, lineWidth: 1))
        )
    }
}

// MARK: - UX-13 leftover selection

/// The checkbox sheet section listing the `~/Library` leftovers found for the non-brew
/// targets, grouped per app. Selection is bound to the caller; every item defaults to
/// checked, and the copy makes clear the files go to the recoverable Trash.
struct UninstallLeftoverSelection: View {
    let groups: [LeftoverGroup]
    @Binding var selected: Set<String>

    private var allPaths: [String] { groups.flatMap { $0.items.map(\.path) } }
    private var allSelected: Bool { !allPaths.isEmpty && selected.isSuperset(of: allPaths) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.minus")
                    .foregroundStyle(Color.wegaHoney)
                    .font(.wega(.body))
                Text(tr("Resztki w ~/Library"))
                    .font(.wega(.callout, weight: .semibold))
                Text("\(allPaths.count)")
                    .font(.wega(.callout, monospaced: true))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(allSelected ? tr("Odznacz wszystko") : tr("Zaznacz wszystko")) {
                    if allSelected { selected.subtract(allPaths) }
                    else { selected.formUnion(allPaths) }
                }
                .buttonStyle(.plain)
                .font(.wega(.subheadline))
                .foregroundStyle(Color.wegaHoney)
            }
            Text(tr("Zaznaczone pliki trafią do Kosza — możesz je stamtąd przywrócić."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if groups.count > 1 {
                        Text(group.app.name)
                            .font(.wega(.subheadline, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.items, id: \.path) { url in
                        UninstallLeftoverRow(
                            url: url,
                            isOn: selected.contains(url.path),
                            toggle: { toggle(url.path) }
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func toggle(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }
}

private struct UninstallLeftoverRow: View {
    let url: URL
    let isOn: Bool
    let toggle: @MainActor @Sendable () -> Void

    private var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Toggle(isOn: selectionToggleBinding(isOn: isOn, toggle: toggle)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.wega(.subheadline, weight: .medium))
                    Text(displayPath)
                        .font(.wega(.footnote, monospaced: true))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(WegaCheckboxToggleStyle(glyphFont: .wega(.body), spacing: 10))
        .accessibilityLabel(displayPath)
    }
}
