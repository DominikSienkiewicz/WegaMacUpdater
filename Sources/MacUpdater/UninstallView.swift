import SwiftUI
import AppKit
import MacUpdaterCore

struct UninstallView: View {
    var onWegaState: ((WegaState) -> Void)?
    /// An app bundle a Cleanup row handed over; selected once, after the first scan lists it.
    var preselection: URL? = nil
    var onPreselectionUsed: () -> Void = {}
    var duplicateBundleIdentifier: String?
    var onEndDuplicateReview: () -> Void = {}

    @EnvironmentObject private var model: AppViewModel
    /// The Settings window hosts the helper card that turns Wega's helper on.
    @Environment(\.openSettings) private var openSettings

    @State private var apps:          [ApplicationInfo] = []
    @State private var duplicateReview: UninstallDuplicateReview?
    @State private var pendingDuplicateReview: UninstallDuplicateReview?
    @State private var protections:    [String: UninstallProtection] = [:]
    @State private var selected:       Set<String>       = []
    @State private var search:         String            = ""
    /// UXP-23 — ⌘F focuses the search field below.
    @FocusState private var searchFocused: Bool
    @StateObject private var operations = UninstallCoordinator()
    /// What the uninstall changes is what the inventory lists; it is told once the run ends.
    @EnvironmentObject private var inventory: InventoryStore
    private let announcer: any AccessibilityAnnouncing = LiveAccessibilityAnnouncer()
    @State private var showDialog:     Bool              = false
    /// UX-01: the exact visible installations named by the confirmation. Execution
    /// consumes this frozen collection instead of resolving selection through a filter
    /// for a second time after consent.
    @State private var pendingUninstallTargets: [ApplicationInfo] = []
    /// REL-14: whether the scan behind `pendingUninstallTargets` was incomplete, frozen
    /// at confirmation time so the dialog can warn that the target list may be partial.
    @State private var pendingScanIncomplete: Bool = false
    /// UX-13: home-folder leftovers found for the non-brew targets, planned by the coordinator
    /// before the confirm sheet opens so it can offer them as checkboxes.
    @State private var pendingLeftoverGroups: [LeftoverGroup] = []
    /// The cask catalog could not be loaded for the sheet, so no Homebrew zap list was used.
    @State private var pendingLeftoverCatalogUnavailable: Bool = false
    /// The scan behind the sheet could not read the applications, frozen when the sheet opens.
    @State private var pendingApplicationsIncomplete: Bool = false
    /// UX-13: which leftover paths the user has ticked for the Trash. The sheet opens with
    /// `UninstallLeftoverPresentation.defaultSelection`; the user ticks or unticks the rest.
    @State private var selectedLeftovers: Set<String> = []
    /// The running state of `pendingUninstallTargets`, computed when the sheet opens.
    @State private var pendingRunningStates: [String: RunningApplicationResolution] = [:]
    /// The sheet is being prepared (routes and leftovers awaited); a second press is ignored.
    @State private var isPreparingDialog: Bool = false
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
    /// The last scan could not read the applications, so the list of other installed apps that
    /// may still use a leftover is partial. A Homebrew failure alone does not count.
    @State private var applicationsSourceFailed: Bool    = false
    @State private var banner:         BannerData?

    private var isLoading: Bool { operations.isScanning }
    private var isUninstalling: Bool { operations.isUninstalling || operations.isQuitting }

    /// REL-14: resolves the list body between loading, a failed scan, an empty machine
    /// and populated results, so a scan failure is never shown as "no apps found".
    private var listState: UninstallListState {
        UninstallListState.resolve(isLoading: isLoading, appsEmpty: appRows.isEmpty, scanFailed: scanFailed)
    }

    private var appRows: [ApplicationInfo] {
        if duplicateBundleIdentifier != nil { return duplicateReview?.visibleApps ?? [] }
        return apps
    }

    private var filtered: [ApplicationInfo] {
        guard !search.isEmpty else { return appRows }
        return appRows.filter { $0.name.localizedCaseInsensitiveContains(search) }
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
                        Text(duplicateBundleIdentifier == nil
                             ? tr("Brew casks → brew uninstall  ·  pozostałe → Kosz")
                             : tr("Wybierz jedną kopię do odinstalowania. Dane aplikacji zostaną zachowane."))
                            .font(.wega(.subheadline, monospaced: true))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if duplicateBundleIdentifier != nil {
                        Button(tr("Wszystkie aplikacje"), action: onEndDuplicateReview)
                            .disabled(isUninstalling || isPreparingDialog)
                    }
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
                    .disabled(targets.isEmpty || isUninstalling || isPreparingDialog)
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
                        if duplicateBundleIdentifier == nil {
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
                        }
                        Text(targets.isEmpty
                             ? trp("%@ aplikacji", filtered.count)
                             : trf("%@ z %@ zaznaczonych", "\(targets.count)", "\(selectableCount)"))
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
                        title: duplicateBundleIdentifier == nil ? tr("Brak aplikacji") : tr("Brak kolejnej kopii"),
                        message: duplicateBundleIdentifier == nil ? tr("Nie znaleziono żadnych zainstalowanych aplikacji.")
                            : tr("W tym skanie nie znaleziono już kilku kopii tej aplikacji.")
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

                                if protection == .wegaItself {
                                    Link(tr("Jak usunąć Wegę i jej pomocnika"), destination: AppEndpoints.shared.uninstallGuideURL)
                                        .font(.wega(.callout))
                                        .padding(.leading, 54)
                                        .padding(.bottom, 8)
                                }

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
        .searchFocused($searchFocused)
        .receivesSearchFocusRequests(on: .uninstall) { searchFocused = true }
        .sheet(isPresented: $showDialog) {
            UninstallDialog(
                targets:     pendingUninstallTargets,
                duplicateReview: pendingDuplicateReview != nil,
                ambiguities: pendingDuplicateReview != nil ? [] : InstallationInventory.ambiguousBrewUninstalls(
                    selected: pendingUninstallTargets,
                    among: apps
                ),
                scanIncomplete: pendingScanIncomplete,
                leftoverGroups: pendingLeftoverGroups,
                leftoverCatalogUnavailable: pendingLeftoverCatalogUnavailable,
                applicationsIncomplete: pendingApplicationsIncomplete,
                measureLeftover: { [operations] in await operations.measureLeftover($0) },
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
        .wegaAttention(showDialog || showForceQuit || scanError != nil)
        .onChange(of: search) { _, _ in
            selected.formIntersection(filtered.map(\.id))
        }
        .task(id: duplicateBundleIdentifier) {
            selected.removeAll()
            duplicateReview = nil
            await scan()
        }
    }

    private func perform(_ action: UninstallResultAction) {
        switch action {
        case .showInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openAppManagementSettings:
            NSWorkspace.shared.open(AppManagementSettings.paneURL)
        case .openHelperSettings:
            SettingsRoute.shared.open(.helper, with: openSettings)
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
        if selected.contains(id) { selected.remove(id) }
        else if duplicateBundleIdentifier != nil { selected = [id] }
        else { selected.insert(id) }
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
        guard duplicateBundleIdentifier == nil else { return }
        let selectableIds = UninstallSelection.selectAll(filtered: filtered, protections: protections)
        if Set(targets.map(\.id)) == selectableIds { selected.removeAll() }
        else { selected = selectableIds }
    }

    /// UX-13: freezes the confirmation targets (UX-01), then plans their home-folder
    /// leftovers via the coordinator so the sheet opens with the checkbox list ready. A second
    /// call while one is preparing returns at once.
    private func presentUninstallDialog() async {
        let targets = self.targets
        guard !targets.isEmpty, !isUninstalling, !isPreparingDialog else { return }
        isPreparingDialog = true
        defer { isPreparingDialog = false }
        pendingUninstallTargets = targets
        pendingDuplicateReview = duplicateReview
        pendingScanIncomplete = scanFailed
        // Read together before any wait: a scan finishing during one would otherwise pair its
        // partial list with the earlier scan's "complete" flag.
        let installed = apps
        let applicationsIncomplete = applicationsSourceFailed
        pendingRoutes = await operations.routes(for: targets)
        // A blocked target is not attempted: it is neither asked to quit nor offers leftovers.
        let attempted = UninstallQuitFlow.partition(targets: targets, routes: pendingRoutes).attempt
        pendingRunningStates = operations.runningStates(for: attempted)
        let leftovers = pendingDuplicateReview == nil
            ? await operations.scanLeftovers(for: attempted, installed: installed)
            : LeftoverScan(groups: [], catalogUnavailable: false)
        pendingLeftoverGroups = leftovers.groups
        pendingLeftoverCatalogUnavailable = leftovers.catalogUnavailable
        pendingApplicationsIncomplete = applicationsIncomplete
        selectedLeftovers = UninstallLeftoverPresentation.defaultSelection(
            leftovers.groups, applicationsIncomplete: applicationsIncomplete
        )
        showDialog = true
    }

    private func cancelUninstall() {
        showDialog = false
        pendingUninstallTargets = []
        pendingDuplicateReview = nil
        pendingScanIncomplete = false
        pendingLeftoverGroups = []
        pendingLeftoverCatalogUnavailable = false
        pendingApplicationsIncomplete = false
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
        leftovers: [LeftoverGroup],
        duplicateReview: UninstallDuplicateReview?
    ) async {
        defer { operations.endQuitPhase() }
        guard let plan = await operations.runQuitPhase(targets: targets, routes: routes, askForceQuit: askForceQuit)
        else { return }
        await uninstall(
            targets: plan.remove, leftovers: leftovers, skipped: plan.skipped, reported: targets,
            options: UninstallRemovalOptions(zap: zap, duplicateReview: duplicateReview)
        )
    }

    private func confirmUninstall(zap: Bool) {
        guard operations.beginQuitPhase() else { return }
        let targets = pendingUninstallTargets
        let routes = pendingRoutes
        let duplicateReview = pendingDuplicateReview
        let leftovers = pendingLeftoverGroups.compactMap { group -> LeftoverGroup? in
            let consented = group.items.filter { selectedLeftovers.contains($0.url.path) }
            return consented.isEmpty ? nil : LeftoverGroup(app: group.app, items: consented)
        }
        showDialog = false
        pendingUninstallTargets = []
        pendingDuplicateReview = nil
        pendingScanIncomplete = false
        pendingLeftoverGroups = []
        pendingLeftoverCatalogUnavailable = false
        pendingApplicationsIncomplete = false
        pendingRunningStates = [:]
        pendingRoutes = [:]
        selectedLeftovers = []
        Task {
            await quitThenUninstall(
                targets: targets, routes: routes, zap: zap && duplicateReview == nil,
                leftovers: leftovers, duplicateReview: duplicateReview
            )
        }
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
        if let duplicateBundleIdentifier {
            applyDuplicateReview(duplicateBundleIdentifier, to: scan)
        } else if let preselection {
            selected = UninstallSelection.preselection(for: preselection, in: apps, protections: protections)
            onPreselectionUsed()
        }
        scanFailed = scan.scanFailed
        applicationsSourceFailed = scan.failures.contains { $0.source == .applications }
        scanError = scan.failures.scanErrorMessage
    }

    private func applyDuplicateReview(_ bundleIdentifier: String, to scan: UninstallScan) {
        let review = UninstallDuplicateReview(
            bundleIdentifier: bundleIdentifier, apps: scan.apps,
            scanComplete: !scan.scanFailed, brewPrefix: BinaryLocator().locateBrewPrefix()
        )
        duplicateReview = review
        for app in review.visibleApps where protections[app.id] == nil && review.target(for: app) == nil {
            protections[app.id] = .unverifiedDuplicateCopy
        }
        selected.formIntersection(review.visibleApps.filter { protections[$0.id] == nil }.map(\.id))
    }

    /// - Parameter reported: every confirmed target, in confirmation order; each one ends in
    ///   exactly one result, whether removed, skipped before removal, or blocked.
    private func uninstall(
        targets: [ApplicationInfo],
        leftovers: [LeftoverGroup],
        skipped: [String: UninstallTargetResult],
        reported reportedApps: [ApplicationInfo],
        options: UninstallRemovalOptions
    ) async {
        let zap = options.zap
        guard !targets.isEmpty else {
            show(UninstallResultPresentation.report(
                results: skipped, apps: reportedApps, leftoversTrashed: 0, leftoversFailed: 0, requestedZap: zap
            ))
            announcer.announce(AnnouncementCopy.uninstallNothingRemoved())
            return
        }
        // REL-06 — `brew uninstall --cask` (with `--zap` it also deletes preferences and
        // Application Support) rewrites the Caskroom, and `UpgradeMutex` only covers upgrades.
        // Without a ticket a quit here ends the process between the Caskroom entry and the
        // bundle, which is the half-removed state the guard exists to prevent.
        let ticket = MutationGuard.shared.begin(trp("odinstalowanie %@ aplikacji", targets.count))
        defer { MutationGuard.shared.end(ticket) }

        banner = nil; result = nil
        onWegaState?(WegaState(pose: .sniff, line: tr("Aport! Zabieram to z dysku…")))

        let outcome = await operations.uninstall(
            targets: targets,
            zap: zap,
            leftovers: leftovers,
            skipped: skipped,
            duplicateReview: options.duplicateReview,
            using: model.brewService
        )
        inventory.markStale()
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
        announcer.announce(succeeded.isEmpty
            ? AnnouncementCopy.uninstallNothingRemoved()
            : AnnouncementCopy.uninstallFinished(removed: succeeded.count))
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
    let duplicateReview: Bool
    /// REL-16: casks whose application is installed in more than one place — see
    /// `InstallationInventory.ambiguousBrewUninstalls`.
    let ambiguities: [AmbiguousBrewUninstall]
    /// REL-14: the scan behind these targets failed to read one or more sources, so the
    /// list may be missing installations. The dialog warns before the destructive action.
    var scanIncomplete: Bool = false
    /// UX-13: the home-folder leftovers planned for the non-brew targets, presented as
    /// checkboxes so the user reviews exactly what "app + leftovers" removes.
    var leftoverGroups: [LeftoverGroup] = []
    /// No Homebrew zap list could be read, so the leftover section says what it is missing.
    var leftoverCatalogUnavailable: Bool = false
    /// The app scan was incomplete, so no leftover is ticked by default and the section says why.
    var applicationsIncomplete: Bool = false
    /// Sizes a leftover once the sheet is open.
    var measureLeftover: @Sendable (URL) async -> LeftoverSize = { _ in .unknown }
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
        duplicateReview: Bool = false,
        ambiguities: [AmbiguousBrewUninstall],
        scanIncomplete: Bool = false,
        leftoverGroups: [LeftoverGroup] = [],
        leftoverCatalogUnavailable: Bool = false,
        applicationsIncomplete: Bool = false,
        measureLeftover: @escaping @Sendable (URL) async -> LeftoverSize = { _ in .unknown },
        runningStates: [String: RunningApplicationResolution] = [:],
        routes: [String: UninstallRouteDecision] = [:],
        isRefreshing: Bool = false,
        selectedLeftovers: Binding<Set<String>> = .constant([]),
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Bool) -> Void
    ) {
        self.targets = targets
        self.duplicateReview = duplicateReview
        self.ambiguities = ambiguities
        self.scanIncomplete = scanIncomplete
        self.leftoverGroups = leftoverGroups
        self.leftoverCatalogUnavailable = leftoverCatalogUnavailable
        self.applicationsIncomplete = applicationsIncomplete
        self.measureLeftover = measureLeftover
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
        case .helper: tr("pomocnik Wegi usunie ją bez hasła")
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
                    Text(trp("Odinstalować %@ aplikacji?", totalCount))
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
                    if brewCount > 0 && !duplicateReview {
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

                    if !counts.removesNothing {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(UninstallScopeSummary.headline(counts: counts, leftovers: selectedLeftovers.count))
                            Text(UninstallScopeSummary.text(
                                counts: counts, leftovers: selectedLeftovers.count, zapMode: zapMode))
                        }
                        .font(.wega(.footnote))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
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
                            Text(trp("%@ aplikacji nie jest zarządzanych przez Homebrew — trafią do Kosza.", trashCount))
                                .font(.wega(.callout))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, brewCount > 0 ? 10 : 0)
                    }

                    // UX-13: "app + leftovers" for non-brew apps — what the app left in the
                    // home folder, presented so the user reviews and consents before it goes
                    // to the (recoverable) Trash.
                    if UninstallLeftoverPresentation.showsSection(
                        groups: leftoverGroups, catalogUnavailable: leftoverCatalogUnavailable
                    ) {
                        UninstallLeftoverSelection(
                            groups: leftoverGroups,
                            selected: $selectedLeftovers,
                            catalogUnavailable: leftoverCatalogUnavailable,
                            applicationsIncomplete: applicationsIncomplete,
                            measure: measureLeftover
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
                        .keyboardShortcut(.delete, modifiers: .command)
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
