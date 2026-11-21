import Combine
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
    var undoableCount:  ((Int) -> Void)?
}

@MainActor
struct ScanStoreDependencies {
    typealias ManualScan = (BrewService, Set<String>) async -> (
        apps: [ManualOutdatedApp],
        failedChecks: Int
    )

    let operations: OperationCoordinator
    let upgrades: UpgradeCoordinator
    let caskAppPathResolver: CaskAppPathResolver
    /// Whether a restored `.app` path still points at something. Separate from the resolver's
    /// own existence check because it answers a different question at a different time: the
    /// resolver asks brew where a bundle *should* be, this asks whether yesterday's answer
    /// is still true before an icon is drawn from it.
    let bundleExists: (URL) -> Bool
    let manualScan: ManualScan
    let reportWindowScan: (Int, Int, String) -> Void
    var recordUpdateRun: (UpdateJournalEntry) -> Void
    let settleAppManagementPermission: ((Bool) -> Void)?
    let undoableUpdates: () -> [UndoableUpdate]
    /// A test's stubbed manual scan. Tried first, before `manualScanWithProgress`, so a test that
    /// copies `.live` and sets this gets its stub rather than the real scanner `.live` carries.
    /// The app leaves it `nil`.
    var detailedManualScan: ((BrewService, Set<String>) async -> ManualScanReport)? = nil
    /// UXP-13 — the manual scan that also reports how many vendor apps have answered: the one
    /// `.live` runs. Tried after `detailedManualScan` and before the legacy `manualScan`.
    var manualScanWithProgress: ((BrewService, Set<String>, @escaping @Sendable (ManualScanProgress) async -> Void) async -> ManualScanReport)? = nil
    var checkVendorUpdate: @Sendable (ManualOutdatedApp) async throws -> VendorUpdateCompletionResult = {
        try await VendorUpdateCompletionChecker().check($0)
    }
    var reportVendorCheck: (ManualOutdatedApp, ManualOutdatedApp?, InstallationCheck?, Int, String) -> Void = { _, _, _, _, _ in
        /* only the live dependencies have a menu-bar agent to report to */
    }
    var teamIDOfApp: @Sendable (URL) async -> String? = { appURL in
        await Task.detached { CodeSignatureVerifier.teamID(ofAppAt: appURL) }.value
    }
    var bundleIdentifierOfApp: (URL) -> String? = { CaskReplacementArtifactIdentity.bundleIdentifier(at: $0) }
    var stopDocker: @Sendable (URL) async -> DockerDesktopStopResult = {
        await DockerDesktopStopper().stop(bundleURL: $0)
    }
    var restartDocker: @Sendable (URL) async -> DockerDesktopRestartResult = {
        await DockerDesktopRestarter().restart(bundleURL: $0)
    }
    var teamIDLedger: TeamIDLedger = .shared
    var rollbackLedger: CaskRollbackLedger = .shared
    var confirmPublisherChange: @MainActor (ScanStore.PublisherChangePrompt) -> Bool = { PublisherChangeAlert.confirm($0) }
    /// F3 — the lock a window run, a manual install and a tap change take. The process-wide
    /// `UpgradeMutex.shared` in the app, so the background round and a migration are excluded;
    /// injectable like the background updater's, so a test's store has one of its own.
    var upgradeMutex: UpgradeMutex = .shared
    /// UXP-14 — when `brew update` last succeeded; decides whether a launch scan refreshes the catalog.
    var catalogStamp: BrewCatalogStamp = .none
    /// The scan's clock: the launch decision, the catalog's age and the stamp it writes.
    var now: @MainActor () -> Date = { Date() }
    /// Tells the menu bar whether this window is scanning, so its own automatic check stands down.
    var reportWindowScanRunning: @MainActor (Bool) -> Void = { _ in }
    /// Where a fully updated run records that the readiness card has done its job
    /// (`ReadinessPresentation.dismissedKey`, which the card reads through `@AppStorage`).
    var defaults: UserDefaults = .standard
    /// Owner decision 2026-11-21 — reads, now, whether the settings `sudo` reads can be trusted;
    /// `nil` when they can. A run asks at its start and before each cask that may ask for the
    /// administrator password. A test's store says it outright; `.live` asks the app's gate.
    var sudoPolicyDistrust: @MainActor () -> SudoPolicyDistrust? = { nil }

    static let live = ScanStoreDependencies(
        operations: .shared,
        upgrades: .shared,
        caskAppPathResolver: CaskAppPathResolver(),
        bundleExists: { FileManager.default.fileExists(atPath: $0.path) },
        manualScan: { brewService, outdatedCasks in
            await ManualUpdateScanner(brewService: brewService).scan(
                brewOutdatedCasks: outdatedCasks
            )
        },
        reportWindowScan: { count, failedChecks, fingerprint in
            MenuBarAgent.shared.reportWindowScan(
                count: count,
                failedChecks: failedChecks,
                fingerprint: fingerprint
            )
        },
        recordUpdateRun: { UpdateRunJournal().record($0) },
        settleAppManagementPermission: nil,
        undoableUpdates: { UpdateOperationStore.shared.undoableUpdates() },
        manualScanWithProgress: { brew, outdated, report in
            await ManualUpdateScanner(brewService: brew).scanReport(brewOutdatedCasks: outdated, onProgress: report)
        },
        reportVendorCheck: { item, remaining, check, count, fingerprint in
            MenuBarAgent.shared.reportVendorCheck(item: item, remaining: remaining, check: check, count: count, fingerprint: fingerprint)
        },
        catalogStamp: .defaults(.standard),
        reportWindowScanRunning: { MenuBarAgent.shared.setWindowScanRunning($0) },
        sudoPolicyDistrust: { SudoPasswordPromptGate.shared.check() }
    )
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
    @Published var vendorHandoffs: [ManualOutdatedApp] = []
    @Published var vendorCheckPath: String?
    @Published var vendorMessages: [String: String] = [:]
    var vendorCheckTask: Task<Void, Never>?
    var vendorCheckGeneration = 0
    @Published var brewLog:           [String]            = []
    @Published var showLog:           Bool                = false
    @Published var selected:          Set<String>         = []
    @Published var updating:          Bool                = false
    /// UXP-30 — update runs that reached their rescan, so the inventory knows the app set may
    /// have changed, whether or not a window watched the run end.
    @Published private(set) var completedRunCount = 0
    /// Manual installs and reinstalls whose brew process ran, and undos whose restore ran: each
    /// can change the installed apps without a scan, so the inventory counts them too.
    @Published private(set) var completedManualInstallCount = 0
    @Published private(set) var completedUndoCount = 0
    @Published var errorMessage:      String?
    @Published var installationChecks: [InstallationCheck] = []
    @Published var lastCheck:         Date?
    @Published private(set) var banners = BannerQueue<BannerData>()
    @Published var restartCandidates: [RestartInfo]       = []
    var restartDiagnosticOperationIDs: [String: UUID] = [:]
    var restartDockerBundleURLs: [String: URL] = [:]
    @Published var restartBusy:       String?
    @Published var pendingForceRestart: RestartInfo?
    @Published var caskIconPaths:     [String: URL]       = [:]
    @Published var caskDownloads:     [String: CaskDownloadInfo] = [:]   // FEAT-03
    @Published var inspectedKey:      String?
    /// M3(b) — casks Homebrew still tracks but whose app bundle is gone. Detected during a
    /// scan, removed only when the user says so.
    @Published var staleCasks:        [String]            = []
    @Published var cleaningStaleCasks = false
    /// M5 — whether each outdated cask is covered by snapshot → canary → auto-rollback.
    @Published var caskProtection:    [String: RollbackProtection.Verdict] = [:]
    /// M2 — the casks the last protection check asked brew about. One of them without a verdict
    /// is one the check found nothing for (brew failed, or left it out): not covered, rather than
    /// "still checking" for good.
    @Published var caskProtectionResolved: Set<String> = []
    /// F2 — what each outdated cask installs. Feeds the "may need an admin password" note.
    @Published var caskProfiles:      [String: CaskArtifactProfile] = [:]
    /// F2 — download sizes, probed on demand. `unknown` is a first-class answer: brew's JSON
    /// carries no size and a CDN may omit `Content-Length`.
    @Published var caskSizes:         [String: DownloadSizeProbeResult] = [:]
    @Published var probingSizes       = false
    @Published var showPlanPreview    = false
    /// M2(c) — where the scan actually is. `nil` before the first one ever runs.
    @Published var progress: ScanProgress?
    /// True while a scan is running *underneath* a result that stays on screen.
    ///
    /// The launch refresh is the reason this exists. A scan with nothing on screen takes the
    /// window over — `status` goes to `.checking` and the scan's own screen replaces the list —
    /// but over a result the restored list would flash up and vanish for a minute, which is
    /// worse than the stale numbers it was meant to correct. In this mode `status` stays
    /// `.results` and only the band, the header and the toolbar say that something is running.
    /// The checks after a run and after an undo over a result run this way too (C2 stage 4).
    @Published private(set) var isRefreshing = false
    /// UXP-13 — true only while `brew update` refreshes Homebrew's catalog, the slow first step
    /// of a full scan. A caption of its own rather than a fifth `ScanPhase`: the ring counts the
    /// four sources, and the catalog is not one of them.
    @Published private(set) var isRefreshingCatalog = false
    /// Whether a new check may start now: none running, none refreshing underneath a result,
    /// and no update or undo in flight. An undo ends in a check of its own, which would hide a
    /// scan started while it restores the app — and that scan would close the summary.
    var canStartCheck: Bool { status != .checking && !isRefreshing && !updating && undoBusy == nil }
    /// Whether ⌘. and the toolbar's „Anuluj” may cancel a scan now: one holds the window or
    /// refreshes under the list, and neither an update nor an undo runs. The run's and the
    /// undo's checks run outside `scanTask`, so `cancelScan()` could not stop them; the run's
    /// is stopped with the run.
    var canCancelScan: Bool { (status == .checking || isRefreshing) && !updating && undoBusy == nil }
    /// UXP-13 — when the running scan started, for the band's elapsed time. `nil` between scans.
    @Published private(set) var scanStartedAt: Date?
    /// UXP-14 — how old the Homebrew catalog is, in minutes, when the scan on screen reused it
    /// instead of running `brew update`. `nil` when the scan refreshed it itself, and for a
    /// result that did not come from this window's scan.
    @Published private(set) var catalogAgeMinutes: Int?
    /// UXP-13 — how many vendor apps the running scan has heard back from. `nil` outside the
    /// vendor phase of the current scan.
    @Published private(set) var manualScanProgress: ManualScanProgress?
    /// UXP-13 — one number per scan, so a vendor report that arrives after its scan has ended
    /// cannot land in the next one.
    private(set) var scanGeneration = 0
    /// How far the running upgrade has got, in whole packages. `nil` when nothing is
    /// installing; the band's run ring and stage read it.
    @Published var upgradeProgress: UpgradeProgress? {
        didSet { publishWindowRun() }
    }
    /// C2 stage 3 — what the running update knows about each planned row and each batch.
    /// Written only at a row's or a batch's boundary, never per output chunk, and only when
    /// it changes.
    @Published private(set) var runBoard = UpdateRunBoard.idle
    /// C2 stage 4 — the last window run's result, open as the after-update summary until
    /// `closeRunReport()`. Written only through `setRunReport(_:)`.
    @Published private(set) var runReport: UpdateRunReport?
    /// The counter behind `upgradeProgress`. One per run, created by the upgrade and read
    /// by the brew streaming loop — a stored property, so it cannot live in the extension
    /// that uses it.
    var upgradeTracker: UpgradeProgressTracker?
    /// How many planned rows have a process running right now.
    ///
    /// Not `@Published`: nothing renders the number itself. It decides only whether the
    /// run's stage may name the package it is installing — with several processes out, any
    /// single name is a claim about the other two as well.
    var inFlightItemCount = 0
    /// Owner decision 2026-11-21 — why this run holds what may ask for the administrator password;
    /// `nil` while the settings `sudo` reads can be trusted. Once set, it stays for the run.
    var passwordHold: SudoPolicyDistrust?
    /// Planned keys this run held for that reason; the report names them.
    var heldForPasswordKeys: Set<String> = []
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
    /// LT-01 — committed updates whose pre-upgrade snapshot is still inside the retention
    /// window, newest first. Drives the "Cofnij aktualizację" section.
    @Published var undoableUpdates:   [UndoableUpdate] = []
    /// LT-01 — the token whose undo is currently restoring, so the row can spin.
    @Published var undoBusy:          String?
    /// UXP-11 — the rule a "Nie aktualizuj" or a skip just wrote, offered back as "Cofnij"
    /// until the toast closes. See `ScanStore+Rules.swift`.
    @Published var ruleUndo: RuleUndoNotice?
    /// Keeps `ruleUndo` honest when a rule changes outside this store, e.g. in Settings.
    private var ruleUndoWatch: AnyCancellable?

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
    /// REL-15 — the live-application snapshot the restart-after-update detection matches cask
    /// bundle URLs against. Injectable so the wiring can be exercised without a real workspace.
    let runningApplicationInspector: any RunningApplicationInspecting
    /// M2(b) — the last scan, on disk. Read once on first appearance, written after each
    /// completed scan, so a relaunch shows the previous list instead of an empty hero.
    private let resultStore: ScanResultStore
    let dependencies: ScanStoreDependencies
    private var restoredLastScan = false
    /// `UpdateView.onAppear` fires again on every tab switch and on every language re-key, so
    /// the launch refresh needs the same one-shot latch the restore has — without it, walking
    /// between destinations would kick off a scan each time.
    private var startedLaunchRefresh = false
    /// M2(c) — the scan runs here, not in a view. A `Task` started from `UpdateView` died
    /// with the view tree; this one outlives a language re-key and a tab switch, and gives
    /// **Cancel** something to cancel.
    var scanTask: Task<Void, Never>?
    /// REL-12 — whether the running upgrade has been asked to stop, and what stopping it
    /// cost. Written only through the three operations below.
    @Published private(set) var updateInterruption = UpdateInterruption() {
        didSet { publishWindowRun() }
    }

    let announcer: any AccessibilityAnnouncing

    init(
        resultStore: ScanResultStore = ScanResultStore(),
        runningApplicationInspector: any RunningApplicationInspecting = WorkspaceRunningApplicationInspector(),
        dependencies: ScanStoreDependencies = .live,
        announcer: any AccessibilityAnnouncing = LiveAccessibilityAnnouncer()
    ) {
        self.announcer = announcer
        self.resultStore = resultStore
        self.runningApplicationInspector = runningApplicationInspector
        self.dependencies = dependencies
        ruleUndoWatch = UpdatePolicyStore.shared.$entries.sink { [weak self] entries in
            MainActor.assumeIsolated {
                self?.dropRuleUndo(ifStaleIn: entries)
                self?.deselectRows(hiddenBy: entries)
            }
        }
    }

    /// Services are owned by the app-level `AppViewModel`; hand them over on first appearance.
    func attach(model: AppViewModel) {
        self.model = model
        MenuBarAgent.shared.stopWindowRun = { [weak self] in self?.cancelUpdate() }
        MenuBarAgent.shared.revealInWindow = { [weak self] key in self?.inspectedKey = key }
    }

    // MARK: - REL-12: stopping a running update

    /// "Anuluj" for the longest operation in the app.
    ///
    /// An upgrade already under way is *not* killed: `brew` is replacing an app bundle, and a
    /// process shot mid-write leaves one behind half-replaced. The request is recorded and
    /// honoured at the next package boundary — the package running finishes, nothing after it
    /// starts.
    func cancelUpdate() {
        guard updating, !updateInterruption.isRequested else { return }
        updateInterruption.request()
        WegaLog.info(.homebrew, "Anulowanie aktualizacji — zatrzymam po bieżącym pakiecie")
    }

    /// UXP-09 — hands the menu bar what it shows of the run: done/total and whether a stop was
    /// asked for, whichever path asked (⌘., the band's stop, the menu itself). The brew loop sets
    /// `upgradeProgress` on every output chunk, and every assignment to the agent's
    /// `@Published` property re-evaluates the `App` body, so only a change is assigned.
    private func publishWindowRun() {
        let run = upgradeProgress.map {
            WindowRunStatus(completedUnits: $0.completedUnits, totalUnits: $0.totalUnits,
                            isStopping: updateInterruption.isRequested)
        }
        guard MenuBarAgent.shared.windowRun != run else { return }
        MenuBarAgent.shared.windowRun = run
    }

    /// Called by the upgrade at every package boundary. `remaining` is everything the run
    /// would still have attempted, recorded as skipped so the report can say so.
    func shouldStopUpdate(before remaining: [String]) -> Bool {
        updateInterruption.shouldStop(before: remaining)
    }

    /// A new run starts with a clean stop switch — a previous cancellation may not leak into
    /// the next upgrade.
    func resetUpdateInterruption() {
        updateInterruption = UpdateInterruption()
    }

    /// What a stopped run says besides its report: the summary's "Aktualizacja przerwana" and
    /// "Nie zaczęłam" say how much it managed and what it left untouched (C2 stage 4); this keeps
    /// Wega's line, the activity and the log line. A stopped run never reads as a finished one.
    func reportInterruptedRun(upgraded: Int) {
        let skipped = updateInterruption.skippedKeys.count
        emitActivitySignal(.idle)
        emitWegaState(WegaState(pose: .idle, line: tr("Przerwałam aktualizację.")))
        WegaLog.info(.homebrew, "Aktualizacja przerwana na granicy pakietu: zaktualizowano \(upgraded), pominięto \(skipped)")
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
        vendorHandoffs = snapshot?.vendorHandoffs ?? []
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
            applyBackgroundResult(background, previousChecks: snapshot?.installationChecks ?? [])
        } else if let snapshot {
            brewOutdated   = snapshot.brew
            masOutdated    = snapshot.mas
            npmOutdated    = snapshot.npm
            manualOutdated = snapshot.manual
            installationChecks = snapshot.installationChecks
            lastCheck      = snapshot.scannedAt
            catalogAgeMinutes = nil
            // REL-09 — a scan that went half-blind stays visibly half-blind across a
            // relaunch. Without this an outage read exactly like "everything is current".
            sourceReports    = snapshot.sources
            failedSources    = snapshot.sources.failedSourceCount
            lastScanComplete = snapshot.isComplete
        } else {
            return
        }

        // The icons come from the file even when the agent's newer lists win: the map is keyed
        // by cask token, so every token the two have in common gets its icon, and one the file
        // has never heard of simply keeps its letter tile.
        caskIconPaths = survivingCaskAppPaths(snapshot?.caskAppPaths ?? [:])
        closeVendorHandoffsConfirmedByScan()

        status = .results
        if !lastScanComplete { warnAboutIncompleteScan() }
        // Deliberately no `emitActivitySignal`: nothing is running. The tab icon must not
        // spin, and the scan-finished sound of `finishScan` would be a lie.
        emitCounts()
    }

    /// UXP-05 — take a menu-bar result the window has not seen. `restoreLastScan` adopts one
    /// once per process; this is the same step for every later background round, so a click on
    /// "new updates" lands on a list that has them. Never while an update or a scan runs — a
    /// launch refresh included, which scans under a list whose `status` stays `.results` — and
    /// never for a result that is not newer than what the window already shows.
    @discardableResult
    func adoptBackgroundResultIfNewer(_ result: MenuBarScanResult) -> Bool {
        guard !updating, status != .checking, !isRefreshing else { return false }
        if let lastCheck, result.scannedAt <= lastCheck { return false }
        applyBackgroundResult(result, previousChecks: installationChecks)
        closeVendorHandoffsConfirmedByScan()
        status = .results
        if !lastScanComplete { warnAboutIncompleteScan() }
        emitCounts()
        return true
    }

    private func applyBackgroundResult(_ background: MenuBarScanResult, previousChecks: [InstallationCheck]) {
        brewOutdated   = background.brew
        masOutdated    = background.mas
        npmOutdated    = background.npm
        manualOutdated = background.manualApps
        installationChecks = InstallationCheck.retainingLastSuccess(background.installationChecks, previous: previousChecks)
        lastCheck      = background.scannedAt
        catalogAgeMinutes = nil
        failedSources  = background.failedChecks
        // Background checks carry the same evidence as the window scan.
        sourceReports     = background.sources
        lastScanComplete  = background.failedChecks == 0
    }

    /// Whether a token → bundle pair belongs to a cask the current result reports as outdated.
    private func isOutdatedCask(_ pair: (key: String, value: URL)) -> Bool {
        brewOutdated?.casks.contains { $0.name == pair.key } ?? false
    }

    /// Drops every restored path whose bundle is no longer there.
    ///
    /// A cask uninstalled since the scan must come back as a letter tile, not as the icon of
    /// an app that is gone — an icon is a claim that the thing is on this machine.
    private func survivingCaskAppPaths(_ paths: [String: URL]) -> [String: URL] {
        paths.filter { dependencies.bundleExists($0.value) }
    }

    /// Correct the restored list without taking the window away from it.
    ///
    /// Called once, from the first `onAppear`, straight after `restoreLastScan()`. With a
    /// result already on screen the scan runs quietly underneath it; with nothing to show —
    /// a first launch, or a snapshot too old to decode — there is no list to protect, so the
    /// ordinary full-screen scan is both honest and what the user would have pressed anyway.
    func startLaunchRefresh() {
#if DEBUG
        guard !Self.layoutRegressionScenarioRequested else { return }
#endif
        guard !startedLaunchRefresh, !updating, status != .checking else { return }
        startedLaunchRefresh = true
        startCheck(refreshesCatalog: BrewCatalogFreshness.refreshesAtLaunch(
            lastRefreshedAt: dependencies.catalogStamp.load(), now: dependencies.now()
        ))
    }

    /// The scan's one door onto `isRefreshing`, which is why the property itself is
    /// `private(set)`: the flag is half of a pair with `status`, and a view that could set
    /// either alone could leave the window claiming a scan that is not running.
    ///
    /// `internal` rather than `private` because the scan lives in `ScanStore+Scanning.swift`,
    /// and a private setter is not reachable across files.
    func setRefreshing(_ refreshing: Bool) {
        isRefreshing = refreshing
    }

    /// UXP-13 — opens a scan's own state: a new generation, the start of its clock and no
    /// vendor count yet. The three below are `private(set)` for the reason `isRefreshing` is.
    func beginScanProgress() {
        scanGeneration += 1
        scanStartedAt = dependencies.now()
        manualScanProgress = nil
        dependencies.reportWindowScanRunning(true)
    }

    func setCatalogAgeMinutes(_ minutes: Int?) {
        catalogAgeMinutes = minutes
    }

    func setRefreshingCatalog(_ refreshing: Bool) {
        isRefreshingCatalog = refreshing
    }

    func countCompletedRun() {
        completedRunCount += 1
    }

    func countManualInstall() {
        completedManualInstallCount += 1
    }

    func countUndo() {
        completedUndoCount += 1
    }

    /// Closes what only a running scan has, on every way out of it: the band goes back to the
    /// results state instead of a clock and a count that no longer move.
    func endScanProgress() {
        isRefreshingCatalog = false
        scanStartedAt = nil
        manualScanProgress = nil
        dependencies.reportWindowScanRunning(false)
    }

    /// C2 stage 3 — opens the run's board: every planned cask and npm row, and each batch the
    /// plan has, starts out waiting.
    func beginRunBoard(planned: [OutdatedItem]) {
        var board = UpdateRunBoard(startedAt: dependencies.now(), planned: Set(planned.map(\.key)))
        for item in planned where item.kind == .cask || item.kind == .npm {
            board.rows[item.key] = .waiting
        }
        for lane in UpdateRunLane.allCases where planned.contains(where: { $0.kind == lane.kind }) {
            board.lanes[lane] = .waiting
        }
        runBoard = board
    }

    /// Ignores a key the board has no row for, and a status the row already has: the lanes
    /// run side by side, and a republished board rebuilds every row that reads it.
    func markRunRow(_ key: String, _ status: UpdateRunRowStatus) {
        guard let current = runBoard.rows[key], current != status else { return }
        runBoard.rows[key] = status
    }

    func markRunLane(_ lane: UpdateRunLane, _ status: UpdateRunRowStatus) {
        guard let current = runBoard.lanes[lane], current != status else { return }
        runBoard.lanes[lane] = status
    }

    /// Planned casks outside `trusted` — vetoed by the publisher check, or left without a
    /// preparation to run on — that the cask lane will never start. One publish for all.
    func markCasksThatWillNotRun(_ planned: [OutdatedItem], trusted: [String]) {
        let trusted = Set(trusted)
        var board = runBoard
        for item in planned where item.kind == .cask && !trusted.contains(item.name) && board.rows[item.key] != nil {
            board.rows[item.key] = .notStarted
        }
        guard board != runBoard else { return }
        runBoard = board
    }

    func endRunBoard() {
        guard runBoard != .idle else { return }
        runBoard = .idle
    }

    /// The one setter of `runReport`: `report(run:planned:…)` opens it, and the doors in
    /// `ScanStore+RunReport` close it (`closeRunReport()`) or mark an undo or a trusted publisher.
    func setRunReport(_ report: UpdateRunReport?) {
        runReport = report
    }

    /// Stores a vendor report from the scan numbered `generation`, when the rule below allows.
    func acceptManualScanProgress(_ progress: ManualScanProgress, generation: Int) {
        guard Self.acceptsManualProgress(progress, current: manualScanProgress, generation: generation,
                                         currentGeneration: scanGeneration, phase: self.progress) else { return }
        manualScanProgress = progress
    }

    /// A vendor report counts only for the scan still running, only while it is in its vendor
    /// phase, and never moves the count backwards.
    nonisolated static func acceptsManualProgress(
        _ progress: ManualScanProgress, current: ManualScanProgress?,
        generation: Int, currentGeneration: Int, phase: ScanProgress?
    ) -> Bool {
        guard generation == currentGeneration, phase == .running(.manual) else { return false }
        guard let current else { return true }
        return progress.checkedApps > current.checkedApps
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
            // Only the casks this result actually lists. `caskIconPaths` is never emptied by a
            // scan that finds nothing outdated, so persisting it whole would let the file
            // accumulate a path for every cask ever updated on this machine.
            caskAppPaths: caskIconPaths.filter(isOutdatedCask),
            sources: sourceReports,
            isComplete: lastScanComplete,
            installationChecks: installationChecks,
            vendorHandoffs: vendorHandoffs
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

    private var reconciledSourceUpdates: (items: [OutdatedItem], manual: [ManualOutdatedApp]) {
        let pendingPaths = Set(vendorHandoffs.map { InstallationIdentity(path: $0.path) })
        let pending = UpdatePlanner.attachingCaskPolicies(to: vendorHandoffs, installationChecks: installationChecks)
        let rows = manualOutdated.filter { !pendingPaths.contains(InstallationIdentity(path: $0.path)) } + pending
        return UpdatePlanner.reconciledUpdates(
            items: UpdatePlanner.outdatedItems(brew: brewOutdated, mas: masOutdated, npm: npmOutdated), manual: rows
        )
    }

    /// Every installable row the scan found, before the user's rules.
    private var itemCandidates: [OutdatedItem] {
        UpdatePlanner.attachingReleaseNotes(
            to: reconciledSourceUpdates.items,
            manual: manualOutdated,
            caskAppPaths: caskIconPaths
        )
    }

    // Keys carry a source tag ("f:", "c:", "a:", "n:"); see UpdatePlanner.
    // Items the user has ignored or pinned below the available version are filtered out.
    var allItems: [OutdatedItem] {
        UpdatePlanner.applyPolicies(itemCandidates, policies: UpdatePolicyStore.shared.policiesMap)
    }

    /// A row a rule hides leaves the queue with it, wherever the rule was written: a pin from
    /// the row's sheet or a rule from Settings, not only "Nie aktualizuj" and a skip. Only ever
    /// removes, so taking a rule back never puts the row into the queue. Fed every change of the
    /// policy store, before the store holds the new `entries`, so it reads them from here.
    func deselectRows(hiddenBy entries: [String: UpdatePolicyEntry]) {
        guard !selected.isEmpty, !entries.isEmpty else { return }
        let policies = entries.mapValues(\.policy)
        let hidden = itemCandidates
            .filter { UpdatePlanner.isSuppressed(key: $0.policyKey, availableVersion: $0.to, policies: policies) }
            .map(\.key)
        guard !selected.isDisjoint(with: hidden) else { return }
        selected.subtract(hidden)
    }

    /// The installable rows the active sidebar category actually renders.
    func visibleItems(for filter: UpdateFilter) -> [OutdatedItem] {
        UpdatePlanner.visibleItems(ServiceVendorUpdatePolicy.batchItems(DockerDesktopUpdatePolicy.batchItems(allItems)), filter: filter)
    }

    /// The exact visible rows the batch button, plan preview and confirmation describe.
    func updateTargets(for filter: UpdateFilter) -> [OutdatedItem] {
        UpdatePlanner.targets(from: ServiceVendorUpdatePolicy.batchItems(DockerDesktopUpdatePolicy.batchItems(allItems)), selectedKeys: selected, filter: filter)
    }

    var dockerManagedUpdates: [ManualOutdatedApp] {
        DockerDesktopUpdatePolicy.managedUpdates(items: allItems, appPaths: caskIconPaths, installationChecks: installationChecks)
    }

    var unresolvedDockerItems: [OutdatedItem] {
        let resolved = Set(dockerManagedUpdates.compactMap(\.caskPolicyToken))
        return allItems.filter { $0.kind == .cask && DockerDesktopUpdatePolicy.isDocker(token: $0.name) && !resolved.contains($0.name) }
    }

    var serviceManagedUpdates: [ManualOutdatedApp] {
        ServiceVendorUpdatePolicy.managedUpdates(items: allItems, appPaths: caskIconPaths, installationChecks: installationChecks)
    }

    /// A backstop for what the scan's own filter cannot reach (a restored snapshot): a vendor
    /// cask that a complete scan shows not installed or already current is no card.
    var unresolvedServiceItems: [OutdatedItem] {
        let covered = Set((serviceManagedUpdates + vendorHandoffs).compactMap(\.caskPolicyToken))
        let stale = ServiceVendorUpdatePolicy.staleVendorTokens(
            outdated: brewOutdated?.casks ?? [], installationChecks: installationChecks, scanComplete: lastScanComplete
        )
        return allItems.filter { item in
            item.kind == .cask && ServiceVendorUpdatePolicy.requiresVendor(token: item.name)
                && !covered.contains(item.name) && !stale.contains(item.name)
        }
    }

    /// Every manual update the scan found, before the user's rules.
    private var manualCandidates: [ManualOutdatedApp] {
        let rows = reconciledSourceUpdates.manual
        let existingPaths = Set(rows.map { InstallationIdentity(path: $0.path) })
        let managed = (dockerManagedUpdates + serviceManagedUpdates).filter { !existingPaths.contains(InstallationIdentity(path: $0.path)) }
        return (rows + managed).map(DockerDesktopUpdatePolicy.vendorUpdate)
    }

    /// Manual updates with ignore/pin rules applied.
    var visibleManual: [ManualOutdatedApp] {
        UpdatePlanner.applyPolicies(manualCandidates, policies: UpdatePolicyStore.shared.policiesMap)
    }

    /// UXP-11 — one entry per rule that hides something this scan found, in the order Settings
    /// lists them. A rule that hides nothing today (a pin the offer stays under) is not here.
    var rulesHidingResults: [UpdatePolicyEntry] {
        let policies = UpdatePolicyStore.shared.policiesMap
        guard !policies.isEmpty else { return [] }
        let items = itemCandidates.map { (keys: [$0.policyKey], available: $0.to) }
        // The same two keys `UpdatePlanner.applyPolicies` reads for a manual app.
        let manual = manualCandidates.map { app in
            (keys: [app.policyKey] + (app.caskPolicyToken.map { [UpdatePlanner.key(name: $0, kind: .cask)] } ?? []),
             available: app.availableVersion)
        }
        let hiding = Set((items + manual).flatMap { candidate in
            candidate.keys.filter { UpdatePlanner.isSuppressed(key: $0, availableVersion: candidate.available, policies: policies) }
        })
        return UpdatePolicyStore.shared.sortedEntries.filter { hiding.contains($0.key) }
    }

    /// The update currently shown in the inspector pane, resolved from `inspectedKey`
    /// against the same lists the list column renders — so the inspector always
    /// reflects live data (e.g. after a rescan) rather than a stale snapshot.
    var inspectedUpdate: InspectedUpdate? {
        guard let key = inspectedKey else { return nil }
        if let item = allItems.first(where: { $0.key == key }) {
            if item.kind == .cask, let managed = serviceManagedUpdates.first(where: { $0.caskPolicyToken == item.name }),
               let app = visibleManual.first(where: {
                   InstallationIdentity(path: $0.path) == InstallationIdentity(path: managed.path) && $0.bundleIdentifier == managed.bundleIdentifier
               }) {
                return .manual(app)
            }
            if item.kind == .cask, DockerDesktopUpdatePolicy.isDocker(token: item.name),
               let path = caskIconPaths[item.name],
               let app = visibleManual.first(where: { InstallationIdentity(path: $0.path) == InstallationIdentity(path: path) }) {
                return .manual(app)
            }
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
        app.releaseNotes.map { ReleaseNotesTriage.heuristic($0.plainText).isLikelySecurityFix } ?? false
    }

    /// Selections cannot survive invisibly across filters. Keeping this invariant in the
    /// store also protects a rebuilt SwiftUI tree whose first `onChange` never fires.
    func restrictSelection(to filter: UpdateFilter) {
        selected.formIntersection(visibleItems(for: filter).map(\.key))
    }

    /// Refused while the after-update summary is open: its rows are not the list's.
    func toggleAll(filter: UpdateFilter) {
        guard runReport == nil else { return }
        restrictSelection(to: filter)
        selected = UpdatePlanner.toggledAll(selected: selected, allKeys: visibleItems(for: filter).map(\.key))
    }

    /// UXP-23 — ⇧⌘A: queues every batch row `filter` shows, never a manual app or a row a rule
    /// hides. Refused, like the select-all checkbox, while no result is on screen, while a
    /// refresh replaces it, while an update owns it and while the after-update summary does.
    func selectAllVisible(filter: UpdateFilter) {
        guard status == .results, runReport == nil,
              ScanSelectionGate.allowsListSelection(isRefreshing: isRefreshing, isUpdating: updating) else { return }
        restrictSelection(to: filter)
        selected.formUnion(visibleItems(for: filter).map(\.key))
    }

    /// Refused while an update runs: the rule would take a row the run may still be installing
    /// out of its queue. The list offers no menu then; this also covers every other caller.
    func ignoreItem(_ item: OutdatedItem) {
        guard !updating else { return }
        let previous = UpdatePolicyStore.shared.entries[item.policyKey]
        UpdatePolicyStore.shared.ignore(key: item.policyKey, name: item.name)
        selected.remove(item.key)
        noteRuleChange(key: item.policyKey, previous: previous, message: trf("Nie będę proponować aktualizacji %@.", item.name))
    }

    func ignoreManual(_ app: ManualOutdatedApp) {
        let previous = UpdatePolicyStore.shared.entries[app.policyKey]
        UpdatePolicyStore.shared.ignore(key: app.policyKey, name: app.name)
        noteRuleChange(key: app.policyKey, previous: previous, message: trf("Nie będę proponować aktualizacji %@.", app.name))
    }

    /// UX-12 — skip just the version currently on offer; a later release surfaces again.
    /// No-op when the source can't name the available version (nothing concrete to skip), and
    /// refused while an update runs, like `ignoreItem`.
    func skipItem(_ item: OutdatedItem) {
        guard !updating, let version = item.to, !version.isEmpty else { return }
        let previous = UpdatePolicyStore.shared.entries[item.policyKey]
        UpdatePolicyStore.shared.skip(key: item.policyKey, name: item.name, version: version)
        selected.remove(item.key)
        noteRuleChange(key: item.policyKey, previous: previous,
                       message: trf("Pominęłam wersję %@ aplikacji %@. Następną pokażę.", version, item.name))
    }

    func skipManual(_ app: ManualOutdatedApp) {
        guard let version = app.availableVersion, !version.isEmpty else { return }
        let previous = UpdatePolicyStore.shared.entries[app.policyKey]
        UpdatePolicyStore.shared.skip(key: app.policyKey, name: app.name, version: version)
        noteRuleChange(key: app.policyKey, previous: previous,
                       message: trf("Pominęłam wersję %@ aplikacji %@. Następną pokażę.", version, app.name))
    }

    /// The banner currently on screen, if any.
    var banner: BannerData? { banners.current }

    /// Ordinary notices — a scan result, a failed run's fix. The newest one wins.
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
        UpdatePlanner.unifiedCount(installable: ServiceVendorUpdatePolicy.batchItems(DockerDesktopUpdatePolicy.batchItems(allItems)).count,
                                   manual: visibleManual.count + unresolvedDockerItems.count + unresolvedServiceItems.count)
    }

    /// Badge, error, footer and category counts — all derived from the current lists,
    /// so this is safe to call both at the end of a scan and after a view rebuild.
    func emitCounts() {
        sinks.badgeChange?(updateCount.badgeCount)
        sinks.errorCount?(failedSources)
        let counts = scopeCounts
        sinks.footerInfo?(lastCheck, counts.security)
        sinks.categoryCounts?(counts.apps, counts.cli)
    }

    /// M1 — the updates the band says you finish with the developer, counted as the category on
    /// screen lists them: every manual row under All and Apps, only the security-flagged ones
    /// under Security, none under CLI.
    func handOffCount(for filter: UpdateFilter) -> Int {
        switch filter {
        case .all, .apps: updateCount.manual
        case .cli:        0
        case .security:   visibleManual.filter(isSecurityApp).count
        }
    }

    /// UX-16 — the per-category counts the Updates scope bar shows and the sidebar badge sums.
    var scopeCounts: UpdateScopeCounts {
        UpdateScopeCounts(
            apps: ServiceVendorUpdatePolicy.batchItems(DockerDesktopUpdatePolicy.batchItems(allItems)).filter { $0.kind.category == .apps }.count
                + visibleManual.count + unresolvedDockerItems.count + unresolvedServiceItems.count,
            cli: allItems.filter { $0.kind.category == .cli }.count,
            security: visibleManual.filter(isSecurityApp).count
        )
    }

    /// Publishes the "Cofnij aktualizacje" badge. `sinks` is private to this file, so the
    /// emit lives here and `refreshUndoableUpdates()` — the one writer of
    /// `undoableUpdates` — calls it.
    func emitUndoableCount() {
        sinks.undoableCount?(undoableUpdates.count)
    }
}
