import Foundation
import MacUpdaterCore

enum UpdateStatus { case ready, checking, results }

/// Where a scan's derived values go: sidebar badges, the tab icon, the window footer and
/// Wega's mood line. They all live as `@State` in the view tree, which the language
/// re-key throws away — so `ScanStore` holds them as one replaceable bundle rather than
/// reaching into the view.
struct ScanSinks {
    var wegaState:      ((WegaState) -> Void)?
    var badgeChange:    ((Int) -> Void)?
    var errorCount:     ((Int) -> Void)?
    var activity:       ((UpdateActivity) -> Void)?
    var footerInfo:     ((Date?, Int) -> Void)?
    var categoryCounts: ((Int, Int) -> Void)?
}

/// Owns everything a scan or an upgrade produces, plus the tasks that produce it.
///
/// This lives as a `@StateObject` on the `App`, above the `.id(localization.language)`
/// that re-keys the window on a language switch. `tr(...)` is not reactive, so that
/// re-key is how live language switching works — but it destroys the whole view tree
/// and with it any `@State`. Parking scan results here means a user who switches
/// language after a two-minute scan keeps the results, and a long-running upgrade keeps
/// writing somewhere the UI still reads from.
///
/// This file holds the state and the small operations over it. The scan and the upgrade
/// that *produce* that state live in `ScanStore+Actions.swift` — see the note there for why
/// a few members below are `internal` rather than `private`.
@MainActor
final class ScanStore: ObservableObject {
    @Published var status:            UpdateStatus        = .ready
    @Published var brewOutdated:      BrewOutdated?
    @Published var masOutdated:       [MasOutdatedApp]    = []
    @Published var npmOutdated:       [NpmGlobalOutdated] = []
    @Published var manualOutdated:    [ManualOutdatedApp] = []
    @Published var manualBusy:        String?
    @Published var brewLog:           [String]            = []
    @Published var showLog:           Bool                = false
    @Published var selected:          Set<String>         = []
    @Published var updating:          Bool                = false
    @Published var errorMessage:      String?
    @Published var lastCheck:         Date?
    @Published private(set) var banners = BannerQueue<BannerData>()
    @Published var restartCandidates: [RestartInfo]       = []
    @Published var restartBusy:       String?
    @Published var caskIconPaths:     [String: URL]       = [:]
    @Published var caskDownloads:     [String: CaskDownloadInfo] = [:]   // FEAT-03
    @Published var inspectedKey:      String?
    /// M3(b) — casks Homebrew still tracks but whose app bundle is gone. Detected during a
    /// scan, removed only when the user says so.
    @Published var staleCasks:        [String]            = []
    @Published var cleaningStaleCasks = false
    /// M5 — whether each outdated cask is covered by snapshot → canary → auto-rollback.
    @Published var caskProtection:    [String: RollbackProtection.Verdict] = [:]
    /// F2 — what each outdated cask installs. Feeds the "may need an admin password" note.
    @Published var caskProfiles:      [String: CaskArtifactProfile] = [:]
    /// F2 — download sizes, probed on demand. `unknown` is a first-class answer: brew's JSON
    /// carries no size and a CDN may omit `Content-Length`.
    @Published var caskSizes:         [String: DownloadSizeProbeResult] = [:]
    @Published var probingSizes       = false
    @Published var showPlanPreview    = false
    /// M2(c) — where the scan actually is. `nil` before the first one ever runs.
    @Published var progress: ScanProgress?
    /// F4 — tools the user has not installed. An invitation to install them, not an error.
    @Published var unavailableSources = 0
    /// REL-09 — what each source of the result currently on screen answered. Survives a
    /// relaunch through `ScanSnapshot`, so an outage stays visible after a restart.
    @Published private(set) var sourceReports = ScanSourceReports()
    /// REL-09 — whether the result on screen came from a scan that heard from every source.
    /// `true` before the first scan: an empty screen makes no claim either way.
    @Published private(set) var lastScanComplete = true
    /// F4 — false when `brew` is absent. Drives the soft "install Homebrew" card.
    @Published var brewAvailable      = true

    /// Rebound on every appearance of the view that owns the backing `@State` — see
    /// `bind(_:)`. Replayed from `replayLastScan()` so a rebuilt tree does not show an
    /// empty badge next to a full result list.
    private var sinks = ScanSinks()

    /// Last values pushed through the sinks above, kept so a rebuilt view tree can be
    /// brought back in sync without re-running the scan.
    private var lastWegaState: WegaState?
    private var lastActivity:  UpdateActivity?
    var failedSources: Int = 0
    /// REL-02 — the sources whose outdated list the last scan could actually re-read, which
    /// is what makes a post-upgrade rescan able to *confirm* anything. Deliberately not
    /// derived from `failedSources`: that also counts the manual per-app checkers, and a
    /// flaky vendor endpoint says nothing about whether `brew outdated` answered.
    var confirmedSourceKinds: Set<OutdatedItem.Kind> = []

    var model: AppViewModel?
    let processes = RunningProcessService()
    /// M2(b) — the last scan, on disk. Read once on first appearance, written after each
    /// completed scan, so a relaunch shows the previous list instead of an empty hero.
    private let resultStore: ScanResultStore
    private var restoredLastScan = false
    /// M2(c) — the scan runs here, not in a view. A `Task` started from `UpdateView` died
    /// with the view tree; this one outlives a language re-key and a tab switch, and gives
    /// **Cancel** something to cancel.
    var scanTask: Task<Void, Never>?

    init(resultStore: ScanResultStore = ScanResultStore()) {
        self.resultStore = resultStore
    }

    /// Services are owned by the app-level `AppViewModel`; hand them over on first appearance.
    func attach(model: AppViewModel) {
        self.model = model
    }

    /// M2(a)+(b) — put a result on screen **now**, before any scanning starts.
    ///
    /// Two sources compete: the snapshot on disk from a previous launch, and the lists the
    /// menu-bar agent already built during its last background check (it used to compute
    /// them and throw everything but the count away). The newer one wins. Neither claims to
    /// be current — `freshness` decides how loudly the UI has to say when it was taken.
    func restoreLastScan() {
        guard !restoredLastScan, status == .ready else { return }
        restoredLastScan = true

        let snapshot = resultStore.load()
        let background = MenuBarAgent.shared.lastResult

        // Prefer whichever was taken later; a nil timestamp can never win.
        let useBackground: Bool
        switch (snapshot?.scannedAt, background?.scannedAt) {
        case (nil, nil):            return
        case (nil, _):              useBackground = true
        case (_, nil):              useBackground = false
        case (let s?, let b?):      useBackground = b > s
        }

        if useBackground, let background {
            brewOutdated   = background.brew
            masOutdated    = background.mas
            npmOutdated    = background.npm
            manualOutdated = background.manualApps
            lastCheck      = background.scannedAt
            failedSources  = background.failedChecks
            // The agent keeps a count, not per-source detail — enough to know the result is
            // not the whole picture, which is the part that must not be lost.
            sourceReports     = ScanSourceReports()
            lastScanComplete  = background.failedChecks == 0
        } else if let snapshot {
            brewOutdated   = snapshot.brew
            masOutdated    = snapshot.mas
            npmOutdated    = snapshot.npm
            manualOutdated = snapshot.manual
            lastCheck      = snapshot.scannedAt
            // REL-09 — a scan that went half-blind stays visibly half-blind across a
            // relaunch. Without this an outage read exactly like "everything is current".
            sourceReports    = snapshot.sources
            failedSources    = snapshot.sources.failedSourceCount
            lastScanComplete = snapshot.isComplete
        } else {
            return
        }

        status = .results
        if !lastScanComplete { warnAboutIncompleteScan() }
        // Deliberately no `emitActivitySignal`: nothing is running. The tab icon must not
        // spin, and the scan-finished sound of `finishScan` would be a lie.
        emitCounts()
    }

    /// REL-09 — says out loud that the result on screen came from a scan that did not
    /// finish asking. Raised on restore, where there is no scan-result banner to carry it
    /// and where the list would otherwise read as an answer rather than a partial one.
    private func warnAboutIncompleteScan() {
        let detail = sourceReports.errors.first
        showBanner(BannerData(
            variant: .danger,
            title: tr("Lista może być niepełna"),
            message: detail ?? tr("Ostatni skan nie dostał odpowiedzi od wszystkich źródeł — odśwież, żeby poznać pełną listę."),
            action: .openLogs
        ))
        for error in sourceReports.errors {
            WegaLog.error(.scanner, "Ostatni skan był niepełny: \(error)")
        }
    }

    /// How old the result on screen is. `nil` when nothing has ever been scanned.
    func freshness(now: Date = Date()) -> ScanFreshness? {
        lastCheck.map { ScanFreshness.of(scannedAt: $0, now: now) }
    }

    /// REL-09 — the one door through which a finished scan replaces the per-source picture.
    ///
    /// `sourceReports` and `lastScanComplete` keep their `private(set)` even though the scan
    /// that writes them now lives in `ScanStore+Actions.swift`: a `private` setter is not
    /// reachable across files, and widening it would let any view assign either half of a
    /// pair that only means anything set together.
    func applyScanSourceReports(_ reports: ScanSourceReports) {
        sourceReports    = reports
        lastScanComplete = reports.isComplete
    }

    /// Persist what the last scan found, so the next launch has something to show at once.
    func persistLastScan() {
        guard let lastCheck else { return }
        // REL-09 — `brewOutdated` goes to disk as it is, `nil` included: a source that never
        // answered must not come back as one that answered "nothing".
        let snapshot = ScanSnapshot(
            scannedAt: lastCheck,
            brew: brewOutdated,
            mas: masOutdated,
            npm: npmOutdated,
            manual: manualOutdated,
            sources: sourceReports
        )
        do { try resultStore.save(snapshot) }
        catch { WegaLog.error(.app, "Nie udało się zapisać wyniku skanu: \(error.localizedDescription)") }
    }

    /// Re-bind the view-tree sinks. Called on every appearance because the closures
    /// capture `@State` that a language re-key (or a tab switch) has just replaced.
    func bind(_ sinks: ScanSinks) {
        self.sinks = sinks
    }

    /// Push the finished scan's derived values back out after the view tree was rebuilt.
    /// No-op before the first scan completes, so a fresh launch still shows the hero.
    func replayLastScan() {
        guard status == .results else { return }
        if let state = lastWegaState { sinks.wegaState?(state) }
        if let activity = lastActivity { sinks.activity?(activity) }
        emitCounts()
    }

    // Keys carry a source tag ("f:", "c:", "a:", "n:"); see UpdatePlanner.
    // Items the user has ignored or pinned below the available version are filtered out.
    var allItems: [OutdatedItem] {
        UpdatePlanner.applyPolicies(
            UpdatePlanner.outdatedItems(brew: brewOutdated, mas: masOutdated, npm: npmOutdated),
            policies: UpdatePolicyStore.shared.policiesMap
        )
    }

    /// Manual updates with ignore/pin rules applied.
    var visibleManual: [ManualOutdatedApp] {
        UpdatePlanner.applyPolicies(manualOutdated, policies: UpdatePolicyStore.shared.policiesMap)
    }

    /// The update currently shown in the inspector pane, resolved from `inspectedKey`
    /// against the same lists the list column renders — so the inspector always
    /// reflects live data (e.g. after a rescan) rather than a stale snapshot.
    var inspectedUpdate: InspectedUpdate? {
        guard let key = inspectedKey else { return nil }
        if let item = allItems.first(where: { $0.key == key }) {
            return .outdated(item, iconPath: caskIconPaths[item.name])
        }
        if let app = visibleManual.first(where: { "m:" + $0.path.path == key }) {
            return .manual(app)
        }
        return nil
    }

    /// True when a manual app's release notes look like a security fix — used to
    /// narrow the manual sections when `updateFilter.isSecurityOnly`.
    func isSecurityApp(_ app: ManualOutdatedApp) -> Bool {
        app.releaseNotes.map { ReleaseNotesTriage.heuristic($0).isLikelySecurityFix } ?? false
    }

    func toggleAll() {
        selected = UpdatePlanner.toggledAll(selected: selected, allKeys: allItems.map(\.key))
    }

    func ignoreItem(_ item: OutdatedItem) {
        UpdatePolicyStore.shared.ignore(key: item.policyKey, name: item.name)
        selected.remove(item.key)
    }

    func ignoreManual(_ app: ManualOutdatedApp) {
        UpdatePolicyStore.shared.ignore(key: app.policyKey, name: app.name)
    }

    /// The banner currently on screen, if any.
    var banner: BannerData? { banners.current }

    /// Ordinary notices — a scan result, an upgrade summary. The newest one wins.
    func showBanner(_ banner: BannerData) {
        banners.enqueue(banner, sticky: false)
    }

    /// Notices the user must not miss: today, a cask whose publisher Team ID changed.
    /// These queue ahead of anything transient and survive until dismissed by hand —
    /// before M5 the upgrade summary overwrote the publisher alert on its way out.
    func showStickyBanner(_ banner: BannerData) {
        banners.enqueue(banner, sticky: true)
    }

    func dismissBanner() {
        banners.dismissCurrent()
    }

    func emitWegaState(_ state: WegaState) {
        lastWegaState = state
        sinks.wegaState?(state)
    }

    func emitActivitySignal(_ activity: UpdateActivity) {
        lastActivity = activity
        sinks.activity?(activity)
    }

    /// The single count every surface reports (M4): the window header, the sidebar badge,
    /// the menu-bar badge and the notification all read it from here.
    var updateCount: UnifiedUpdateCount {
        UpdatePlanner.unifiedCount(installable: allItems.count, manual: visibleManual.count)
    }

    /// Badge, error, footer and category counts — all derived from the current lists,
    /// so this is safe to call both at the end of a scan and after a view rebuild.
    func emitCounts() {
        sinks.badgeChange?(updateCount.badgeCount)
        sinks.errorCount?(failedSources)
        sinks.footerInfo?(lastCheck, visibleManual.filter(isSecurityApp).count)
        let appsCount = allItems.filter { $0.kind.category == .apps }.count + visibleManual.count
        let cliCount  = allItems.filter { $0.kind.category == .cli }.count
        sinks.categoryCounts?(appsCount, cliCount)
    }
}
