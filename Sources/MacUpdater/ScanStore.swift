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
    private var failedSources: Int = 0

    private var model: AppViewModel?
    private let processes = RunningProcessService()
    /// M2(b) — the last scan, on disk. Read once on first appearance, written after each
    /// completed scan, so a relaunch shows the previous list instead of an empty hero.
    private let resultStore: ScanResultStore
    private var restoredLastScan = false
    /// M2(c) — the scan runs here, not in a view. A `Task` started from `UpdateView` died
    /// with the view tree; this one outlives a language re-key and a tab switch, and gives
    /// **Cancel** something to cancel.
    private var scanTask: Task<Void, Never>?

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
        } else if let snapshot {
            brewOutdated   = snapshot.brew
            masOutdated    = snapshot.mas
            npmOutdated    = snapshot.npm
            manualOutdated = snapshot.manual
            lastCheck      = snapshot.scannedAt
        } else {
            return
        }

        status = .results
        // Deliberately no `emitActivitySignal`: nothing is running. The tab icon must not
        // spin, and the scan-finished sound of `finishScan` would be a lie.
        emitCounts()
    }

    /// How old the result on screen is. `nil` when nothing has ever been scanned.
    func freshness(now: Date = Date()) -> ScanFreshness? {
        lastCheck.map { ScanFreshness.of(scannedAt: $0, now: now) }
    }

    /// Persist what the last scan found, so the next launch has something to show at once.
    private func persistLastScan() {
        guard let lastCheck else { return }
        let snapshot = ScanSnapshot(
            scannedAt: lastCheck,
            brew: brewOutdated ?? BrewOutdated(formulae: [], casks: []),
            mas: masOutdated,
            npm: npmOutdated,
            manual: manualOutdated
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
    private func showBanner(_ banner: BannerData) {
        banners.enqueue(banner, sticky: false)
    }

    /// Notices the user must not miss: today, a cask whose publisher Team ID changed.
    /// These queue ahead of anything transient and survive until dismissed by hand —
    /// before M5 the upgrade summary overwrote the publisher alert on its way out.
    private func showStickyBanner(_ banner: BannerData) {
        banners.enqueue(banner, sticky: true)
    }

    func dismissBanner() {
        banners.dismissCurrent()
    }

    private func emitWegaState(_ state: WegaState) {
        lastWegaState = state
        sinks.wegaState?(state)
    }

    private func emitActivitySignal(_ activity: UpdateActivity) {
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
    private func emitCounts() {
        sinks.badgeChange?(updateCount.badgeCount)
        sinks.errorCount?(failedSources)
        sinks.footerInfo?(lastCheck, visibleManual.filter(isSecurityApp).count)
        let appsCount = allItems.filter { $0.kind.category == .apps }.count + visibleManual.count
        let cliCount  = allItems.filter { $0.kind.category == .cli }.count
        sinks.categoryCounts?(appsCount, cliCount)
    }
}

// MARK: - Scan & update actions
//
// Split into an extension (same file, so `private` state stays accessible) to keep the
// `ScanStore` body within SwiftLint's type_body_length budget.
extension ScanStore {
    /// Kicks off a scan owned by the store. Idempotent: a second press while one is running
    /// is ignored rather than racing a second `brew update` against the first.
    func startCheck() {
        guard scanTask == nil else { return }
        scanTask = Task { @MainActor [weak self] in
            await self?.runCheck()
            self?.scanTask = nil
        }
    }

    /// M2(c) — cancellation is not new plumbing: `ProcessRunner` already honours
    /// `Task.isCancelled` end to end and surfaces `.cancelled`. It just had no button.
    func cancelScan() {
        scanTask?.cancel()
    }

    /// Returns `true` when the caller must stop. Freezes progress at the phase we reached,
    /// so the screen can say where it stopped instead of snapping to 0% or to "done".
    private func bailIfCancelled(at phase: ScanPhase, emitActivity: Bool) async -> Bool {
        guard Task.isCancelled else { return false }
        progress = .cancelled(at: phase)
        // Keep whatever the previous scan found rather than blanking the window: an empty
        // list would read as "nothing is outdated", which we have not established.
        status = lastCheck == nil ? .ready : .results
        if emitActivity { emitActivitySignal(.idle) }
        emitWegaState(WegaState(pose: .idle, line: tr("Przerwałam skanowanie.")))
        WegaLog.info(.scanner, "Skan anulowany na etapie: \(phase.commandLabel)")
        return true
    }

    /// `lightweight` skips the two expensive, redundant steps after an upgrade (M2d):
    /// `brew update` (metadata was refreshed minutes ago, at the start of the upgrade) and
    /// the stale-cask sweep (nothing has become stale in the meantime). What remains is a
    /// plain `brew outdated` re-query, which is all the post-upgrade list actually needs.
    func runCheck(emitActivity: Bool = true, lightweight: Bool = false) async {
        guard let model else { return }
        status = .checking
        errorMessage = nil
        if emitActivity { emitActivitySignal(.scanning) }
        WegaLog.info(.scanner, lightweight ? "Lekkie odświeżenie listy" : tr("Skan rozpoczęty"))
        emitWegaState(WegaState(pose: .sniff, line: tr("Węszę po Homebrew…")))

        progress = .running(.brew)

        if !lightweight {
            // Refresh brew metadata before asking what is outdated — otherwise a
            // newly-released cask/formula version that hasn't landed locally yet
            // would be missed even though `brew info` against the API shows it.
            _ = try? await model.brewService.update()
            if await bailIfCancelled(at: .brew, emitActivity: emitActivity) { return }

            // M3(b) — detect stale casks; never uninstall them here. "Check for updates" is a
            // read-only operation, and `brew uninstall --force` behind that button was the
            // single most surprising thing Wega did. The user is offered the cleanup as a card
            // in the results (see `staleCasks`) and the tokens are filtered out of the outdated
            // list below, so deferring the removal cannot resurrect phantom outdated entries.
            let installedTokens = (try? await model.brewService.installedCasks()) ?? []
            if installedTokens.isEmpty {
                staleCasks = []
            } else {
                let installInfo = (try? await model.brewService.caskInstallationInfo(tokens: Array(installedTokens))) ?? []
                staleCasks = StaleCaskDetector().staleCasks(from: installInfo)
            }
        }

        // F4 — an absent tool is "not applicable", never a failure. `brewNotFound` used to
        // land in the generic catch below, so a machine without Homebrew wore a permanent
        // red "the list may be incomplete" banner over a list that was complete.
        var outcomes: [SourceCheckOutcome] = []
        let brewOutcome: SourceCheckOutcome

        do {
            // Stale casks are still reported outdated by brew even though their app is gone
            // — drop them here so the count only ever offers upgrades the user can install.
            brewOutdated = UpdatePlanner.excludingStaleCasks(
                try await model.brewService.outdatedGreedy(),
                staleTokens: staleCasks
            )
            brewOutcome = .succeeded
        }
        catch BrewServiceError.brewNotFound { brewOutdated = nil; brewOutcome = .notInstalled }
        catch { errorMessage = error.localizedDescription; brewOutdated = nil
                brewOutcome = .failed("brew outdated")
                WegaLog.error(.homebrew, "brew outdated: \(error.localizedDescription)") }
        outcomes.append(brewOutcome)
        if await bailIfCancelled(at: .brew, emitActivity: emitActivity) { return }

        progress = .running(.mas)
        do { masOutdated = try await model.masService.outdated(); outcomes.append(.succeeded) }
        catch MasServiceError.masNotFound { masOutdated = []; outcomes.append(.notInstalled) }
        catch { masOutdated = []
                outcomes.append(.failed("Mac App Store"))
                WegaLog.error(.app, "mas outdated: \(error.localizedDescription)") }

        if await bailIfCancelled(at: .mas, emitActivity: emitActivity) { return }

        progress = .running(.npm)
        do { npmOutdated = try await model.npmService.outdated(); outcomes.append(.succeeded) }
        catch NpmServiceError.npmNotFound { npmOutdated = []; outcomes.append(.notInstalled) }
        catch { npmOutdated = []
                outcomes.append(.failed("npm"))
                WegaLog.error(.network, "npm outdated: \(error.localizedDescription)") }

        var failed = UpdatePlanner.failedSourceCount(outcomes)
        // Names of the top-level sources that genuinely went silent, for the scan-end
        // log (each manual-checker failure is logged individually by ManualUpdateScanner).
        var silentSources = UpdatePlanner.failedSourceNames(outcomes)
        unavailableSources = UpdatePlanner.unavailableSourceCount(outcomes)
        brewAvailable = brewOutcome != .notInstalled

        if await bailIfCancelled(at: .npm, emitActivity: emitActivity) { return }

        progress = .running(.manual)
        let brewOutdatedCasks = Set(brewOutdated?.casks.map(\.name) ?? [])
        let scan = await scanManualUpdates(brewOutdatedCasks: brewOutdatedCasks)
        manualOutdated = scan.apps
        failed += scan.failedChecks
        if scan.failedChecks > 0 { silentSources.append("ręczne checki (\(scan.failedChecks))") }

        // Resolve icon paths for outdated casks, and drop entries whose real
        // bundle version already matches `current_version` (self-updating apps
        // like Chrome bump their bundle behind brew's back).
        if let casks = brewOutdated?.casks, !casks.isEmpty {
            let infos = (try? await model.brewService.caskInstallationInfo(tokens: casks.map(\.name))) ?? []

            let drifted = BrewCaskDriftFilter().driftedTokens(outdated: casks, installationInfo: infos)
            if !drifted.isEmpty, var updated = brewOutdated {
                updated.casks.removeAll { drifted.contains($0.name) }
                brewOutdated = updated
            }

            let home = FileManager.default.homeDirectoryForCurrentUser
            var paths: [String: URL] = [:]
            for info in infos where !drifted.contains(info.token) {
                for artifact in info.appArtifacts {
                    let system = SystemPaths.applicationsDirectory.appendingPathComponent(artifact)
                    let user   = home.appendingPathComponent("Applications/\(artifact)")
                    if FileManager.default.fileExists(atPath: system.path) {
                        paths[info.token] = system; break
                    } else if FileManager.default.fileExists(atPath: user.path) {
                        paths[info.token] = user; break
                    }
                }
            }
            caskIconPaths = paths
        }

        // FEAT-03: transparentność pobrania (host + checksum) dla outdated casków.
        if let casks = brewOutdated?.casks, !casks.isEmpty {
            let infos = (try? await model.brewService.caskDownloadInfo(tokens: casks.map(\.name))) ?? []
            caskDownloads = Dictionary(infos.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            caskDownloads = [:]
        }

        await resolveRollbackProtection()

        lastCheck = Date()
        status    = .results
        progress  = .finished

        finishScan(emitActivity: emitActivity, silentSources: silentSources, failedSources: failed)
    }

    /// Reports a finished scan: structured log (breakdown + per-item lines), the tab-icon
    /// status (green/red, unless suppressed for the upgrade flow), the result banner, and
    /// the badge/error counts. Split out of `runCheck` to keep that method's complexity down.
    private func finishScan(emitActivity: Bool, silentSources: [String], failedSources sources: Int) {
        failedSources = sources
        let total = allItems.count + visibleManual.count
        let breakdown = ScanLog.breakdown(items: allItems, manual: visibleManual)
        let silent = silentSources.isEmpty
            ? "wszystkie źródła odpowiedziały"
            : "milczały: \(silentSources.joined(separator: ", "))"
        WegaLog.info(.scanner, "Skan zakończony: \(total) aktualizacji (\(breakdown)) — \(silent)")
        for line in ScanLog.foundLines(items: allItems, manual: visibleManual) {
            WegaLog.info(.scanner, "• \(line)")
        }
        let scanState = UpdatePlanner.scanState(updateCount: total, failedChecks: sources)
        // Tab-icon status: green when the scan completed, red when a source failed.
        // Suppressed when called from `runUpdate` (emitActivity == false), which owns
        // the icon for the whole upgrade flow and sets the final state itself.
        if emitActivity {
            switch scanState {
            case .upToDate, .outdated:          emitActivitySignal(.success)
            case .checkFailed, .partialFailure: emitActivitySignal(.error)
            }
        }
        switch scanState {
        case .upToDate:
            if let msg = errorMessage {
                showBanner(BannerData(variant: .danger, title: tr("Błąd Homebrew"), message: msg, action: .openLogs))
            }
            emitWegaState(WegaState(pose: .happy, line: tr("Wszystko aktualne. Idę się zdrzemnąć.")))
        case .outdated(let n):
            if let msg = errorMessage {
                showBanner(BannerData(variant: .danger, title: tr("Błąd Homebrew"), message: msg, action: .openLogs))
            }
            emitWegaState(WegaState(pose: .alert, line: trf("Znalazłam %@ rzeczy do uporządkowania.", "\(n)")))
        case .checkFailed:
            showBanner(BannerData(variant: .danger,
                                  title: tr("Nie udało się sprawdzić aktualizacji"),
                                  message: errorMessage ?? tr("Część źródeł nie odpowiedziała — sprawdź połączenie z internetem i spróbuj ponownie."),
                                  action: .openLogs))
            emitWegaState(WegaState(pose: .sad, line: tr("Nie dowęszyłam się — chyba nie ma internetu.")))
        case .partialFailure(let updates, let failed):
            showBanner(BannerData(variant: .danger,
                                  title: tr("Lista może być niepełna"),
                                  message: trf("Znalazłam %@ aktualizacji, ale %@ źródeł nie odpowiedziało — sprawdź połączenie i odśwież.", "\(updates)", "\(failed)"),
                                  action: .openLogs))
            emitWegaState(WegaState(pose: .alert, line: trf("Znalazłam %@, ale część źródeł milczy.", "\(updates)")))
        }
        // M4 — the dock badge has one owner (the agent); a window scan hands it the fresh
        // number instead of leaving yesterday's. Only from here, never from `emitCounts()`,
        // which also runs on a bare view rebuild and must not claim a scan just happened.
        MenuBarAgent.shared.reportWindowScan(count: updateCount.badgeCount, failedChecks: sources)
        emitCounts()
        persistLastScan()
    }

    private func scanManualUpdates(brewOutdatedCasks: Set<String> = []) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        guard let model else { return ([], 0) }
        return await ManualUpdateScanner(brewService: model.brewService).scan(brewOutdatedCasks: brewOutdatedCasks)
    }

    func installManual(token: String) async {
        guard let model, manualBusy == nil else { return }
        manualBusy = token
        emitActivitySignal(.scanning)
        let installArgs = BrewService.adoptCaskArguments(token: token)
        brewLog = ["$ brew " + installArgs.joined(separator: " ")]
        showLog = true
        WegaLog.info(.homebrew, "Uruchamiam: brew \(installArgs.joined(separator: " "))")
        emitWegaState(WegaState(pose: .sniff, line: trf("Instaluję %@ przez Brew…", "\(token)")))

        do {
            let stream = try model.brewService.events(arguments: installArgs)
            var exitCode: Int32 = 0
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
            if exitCode == 0 {
                manualOutdated.removeAll {
                    if case .cask(let t) = $0.source { return t == token }
                    return false
                }
                showBanner(BannerData(variant: .success, title: trf("Zaktualizowano %@", "\(token)"), message: tr("Teraz zarządzany przez Homebrew.")))
                emitActivitySignal(.success)
                emitWegaState(WegaState(pose: .happy, line: trf("%@ zaktualizowany i pod opieką Brew.", "\(token)")))
                WegaLog.info(.homebrew, "Zainstalowano \(token) (brew cask)")
            } else {
                showBanner(BannerData(variant: .danger, title: trf("Błąd instalacji %@", "\(token)"), message: tr("Sprawdź logi poniżej.")))
                emitActivitySignal(.error)
                emitWegaState(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
                let reason = ScanLog.brewErrorReason(from: brewLog).map { ": \($0)" } ?? ""
                WegaLog.error(.homebrew, "Instalacja \(token) nieudana (kod \(exitCode))\(reason)")
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            showBanner(BannerData(variant: .danger, title: tr("Błąd instalacji"), message: error.localizedDescription))
            emitActivitySignal(.error)
            emitWegaState(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
            WegaLog.error(.homebrew, "Instalacja \(token): \(error.localizedDescription)")
        }
        manualBusy = nil
    }

    func runUpdate() async {
        guard let model else { return }
        // F3 — never overlap with a background upgrade: both take snapshots and both call
        // `brew upgrade --cask`. The window is the one the user is waiting on.
        guard UpgradeMutex.shared.acquire() else {
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja w toku"),
                                  message: tr("Wega właśnie aktualizuje coś w tle. Spróbuj za chwilę.")))
            return
        }
        defer { UpgradeMutex.shared.release() }
        updating = true
        emitActivitySignal(.scanning)
        brewLog = []
        showLog = true
        emitWegaState(WegaState(pose: .sniff, line: tr("Aktualizuję, chwila…")))

        let plan          = UpdatePlanner.plan(selectedKeys: selected, allKeys: allItems.map(\.key))
        // F2 — the exact argument vectors come from the planner, the same call the preview
        // panel renders. Building them here as well is how a dry-run starts to lie: the
        // `--force` retry path below is precisely the drift that was waiting to happen.
        let commands      = UpdatePlanner.commands(for: plan)
        let formulaArgs   = commands.first { $0.executable == "brew" && !$0.arguments.contains("--cask") }?.arguments
        let caskArgs      = commands.first { $0.executable == "brew" && $0.arguments.contains("--cask") }?.arguments
        let npmCommands   = commands.filter { $0.executable == "npm" }
        let caskNames     = plan.caskNames
        let npmNames      = plan.npmNames
        let hasMasItems   = plan.includesMas
        let n             = plan.count

        // Pre-capture which casks being updated are currently running
        var candidates: [RestartInfo] = []
        for token in caskNames {
            if let info = MacUpdaterConstants.restartMap[token], await isProcessRunning(info.processName) {
                candidates.append(info)
            }
        }

        // FEAT-07: dla casków (duże pobrania) doradczo ostrzeż przy złych warunkach
        // (łącze taryfowe / throttling). Akcja jest user-initiated → kontynuujemy.
        //
        // F2 — the gate used to be fed a hard-coded `200MB + 1`, because `brew info --json`
        // carries no size. It now gets the sum of whatever the HEAD probes could actually
        // measure. When nothing could be measured we keep the old pessimistic assumption
        // (a cask is usually large) but say so in the log, rather than pretending to know.
        if !caskNames.isEmpty {
            await probeDownloadSizes()
            let measured = caskNames.compactMap { token -> Int64? in
                if case .known(let bytes) = caskSizes[token] { return bytes }
                return nil
            }
            let assumedSize: Int64 = 200 * 1024 * 1024 + 1
            let sizeBytes = measured.isEmpty ? assumedSize : measured.reduce(0, +)
            if measured.isEmpty {
                brewLog.append("ℹ️ " + tr("Nie udało się ustalić rozmiaru pobrania — zakładam duży plik."))
            }

            let (net, pow) = await LiveConditions.snapshot()
            if case let .postpone(reason) = DownloadGate.decide(
                sizeBytes: sizeBytes, network: net, power: pow) {
                brewLog.append("⚠️ " + trf("Niekorzystne warunki pobierania (%@) — kontynuuję na żądanie.", "\(reason)"))
                emitWegaState(WegaState(pose: .alert, line: tr("Uwaga: kosztowne łącze lub throttling — pobieram mimo to.")))
            }
        }

        var outcomes: [BrewUpgradeOutcome] = []

        // Brew upgrade — formulae
        if let formulaArgs {
            outcomes.append(await runBrewUpgrade(arguments: formulaArgs))
        }

        // Brew upgrade — casks (FEAT-05 snapshot przed, canary/rollback + FEAT-04 ledger po)
        if let caskArgs, !caskNames.isEmpty {
            let snapshots = snapshotCasks(caskNames)
            var caskOutcome = await runBrewUpgrade(arguments: caskArgs)

            // Auto-recover an interrupted upgrade: if a cask bailed because a stale
            // staged app from a previous, cut-short upgrade is in the way ("already an
            // App at …"), retry just those casks once with --force, which overwrites
            // the leftover. Without this they fail on every attempt until cleaned by hand.
            let retryTokens = caskOutcome.tokensRetryableWithForce
            if !retryTokens.isEmpty {
                brewLog.append("↻ " + trf("Przerwana aktualizacja (%@) — ponawiam z --force.", "\(retryTokens.joined(separator: ", "))"))
                WegaLog.info(.homebrew, "Przerwana aktualizacja casku — ponawiam z --force: \(retryTokens.joined(separator: ", "))")
                let retryOutcome = await runBrewUpgrade(arguments: UpdatePlanner.forcedCaskCommand(tokens: retryTokens).arguments)
                caskOutcome = BrewUpgradeOutcome.merging(original: caskOutcome, forcedRetry: retryOutcome, retriedTokens: retryTokens)
            }

            outcomes.append(caskOutcome)
            await postCaskUpgrade(caskNames, snapshots: snapshots)
        }

        // npm global upgrade — one package at a time (npm semantics).
        for (pkg, command) in zip(npmNames, npmCommands) {
            outcomes.append(await runNpmUpgrade(name: pkg, arguments: command.arguments))
        }

        // MAS upgrade
        if hasMasItems {
            brewLog.append("$ mas upgrade")
            do {
                let result = try await model.masService.upgrade()
                let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
                brewLog.append(contentsOf: lines)
            } catch {
                brewLog.append("error: \(error.localizedDescription)")
                WegaLog.error(.app, "mas upgrade: \(error.localizedDescription)")
            }
        }

        _ = try? await model.brewService.cleanup()

        selected.removeAll()
        restartCandidates = candidates

        // Re-query brew/mas so the list reflects reality, not optimistic clearing.
        // If a cask failed (e.g. "App source not there"), it will still appear here.
        // Suppress its icon signal — the upgrade outcome below sets the final state.
        // M2(d) — lightweight: no second `brew update`, no second stale-cask sweep.
        await runCheck(emitActivity: false, lightweight: true)

        updating = false

        let summary = UpdatePlanner.summarize(outcomes: outcomes)
        let failedTokens = summary.failedTokens
        let needsSudoPassword = summary.needsSudoPassword
        if summary.anyFailure {
            let baseDetail = failedTokens.isEmpty
                ? tr("Brew zgłosił błąd — sprawdź log poniżej.")
                : trf("Nie udało się: %@. Szczegóły w logu.", "\(failedTokens.joined(separator: ", "))")
            let detail = needsSudoPassword
                ? trf("%@ Cask wymaga hasła administratora. Włącz Touch ID, żeby autoryzować aktualizacje odciskiem — bez wpisywania hasła.", "\(baseDetail)")
                : baseDetail
            showBanner(BannerData(variant: .danger,
                                  title: tr("Aktualizacja niekompletna"),
                                  message: detail,
                                  action: needsSudoPassword ? .openSettings : nil))
            emitActivitySignal(.error)
            emitWegaState(WegaState(pose: .alert, line: tr("Część pakietów się nie zaktualizowała.")))
            WegaLog.error(.homebrew, "Aktualizacja niekompletna: \(failedTokens.isEmpty ? "Brew zgłosił błąd" : failedTokens.joined(separator: ", "))")
            // Surface *why* each upgrade failed — the brew error block, not just the
            // token name — so the log explains the failure instead of only flagging it.
            for detail in summary.failureDetails {
                WegaLog.error(.homebrew, detail)
            }
        } else {
            showBanner(BannerData(variant: .success, title: trf("Zaktualizowano %@ pakietów", "\(n)"), message: tr("Wszystko gotowe.")))
            emitActivitySignal(.success)
            emitWegaState(WegaState(pose: .happy, line: trf("Gotowe! %@ pakietów odświeżonych.", "\(n)")))
            WegaLog.info(.homebrew, "Zaktualizowano \(n) pakietów")
        }
    }

    /// Runs `brew <arguments>` streaming output to the log, and returns an
    /// outcome that reflects whether brew *actually* succeeded — exit code 0
    /// alone is unreliable for cask upgrades.
    private func runBrewUpgrade(arguments: [String]) async -> BrewUpgradeOutcome {
        guard let model else { return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: []) }
        brewLog.append("$ brew \(arguments.joined(separator: " "))")
        var captured = ""
        var exitCode: Int32 = 0
        do {
            let stream = try model.brewService.events(arguments: arguments)
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    captured += chunk
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                    if brewLog.count > 500 { brewLog.removeFirst(brewLog.count - 500) }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome.analyze(exitCode: exitCode, output: captured)
    }

    private func runNpmUpgrade(name: String, arguments: [String]) async -> BrewUpgradeOutcome {
        guard let model else { return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: []) }
        brewLog.append("$ npm " + arguments.joined(separator: " "))
        var exitCode: Int32 = 0
        do {
            let stream = try model.npmService.upgradeEvents(name: name)
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                    if brewLog.count > 500 { brewLog.removeFirst(brewLog.count - 500) }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome(
            exitCode: exitCode,
            failedTokens: exitCode == 0 ? [] : [name],
            errorLines: []
        )
    }

    // MARK: FEAT-05 (rollback) + FEAT-04 (watchdog Team ID)

    /// FEAT-05 + FEAT-04, now shared with the background updater so the two can never
    /// diverge on what "safe upgrade" means. See `CaskRollbackGuard`.
    private func snapshotCasks(_ tokens: [String]) -> [String: URL] {
        CaskRollbackGuard.snapshot(tokens: tokens, appPaths: caskIconPaths)
    }

    private func postCaskUpgrade(_ tokens: [String], snapshots: [String: URL]) async {
        let outcomes = await CaskRollbackGuard.verify(tokens: tokens, appPaths: caskIconPaths, snapshots: snapshots)
        for (token, outcome) in outcomes {
            switch outcome {
            case .healthy:
                continue
            case .rolledBack:
                brewLog.append("⚠️ " + trf("%@: nowa wersja nie przeszła kontroli — przywrócono poprzednią.", "\(token)"))
                emitWegaState(WegaState(pose: .alert, line: trf("Cofnęłam %@ — nowa wersja nie przeszła kontroli.", "\(token)")))
            case .rollbackFailed:
                brewLog.append("⚠️ " + trf("%@: nowa wersja nie przeszła kontroli, ale rollback się nie powiódł.", "\(token)"))
            case .publisherChanged(let old, let new):
                showStickyBanner(BannerData(variant: .danger, title: tr("Zmiana wydawcy"),
                                            message: trf("%@: Team ID zmienił się (%@ → %@). Zweryfikuj.", "\(token)", "\(old)", "\(new ?? "—")")))
            }
        }
    }

    private func isProcessRunning(_ name: String) async -> Bool {
        await processes.isRunning(name)
    }

    /// M5 — works out which outdated casks the rollback net actually covers.
    ///
    /// A cask that installs no `.app` cannot be snapshotted, so `postCaskUpgrade` has always
    /// skipped it — silently, with no log line and no hint in the UI. The hole cannot be
    /// closed (there is nothing to clone), only disclosed: the row gets an honest "no
    /// protection" badge, and the log says so before the upgrade runs, not after.
    private func resolveRollbackProtection() async {
        guard let model, let casks = brewOutdated?.casks, !casks.isEmpty else {
            caskProtection = [:]
            caskProfiles = [:]
            return
        }
        let profiles = (try? await model.brewService.caskArtifactProfiles(tokens: casks.map(\.name))) ?? []
        var verdicts: [String: RollbackProtection.Verdict] = [:]
        for profile in profiles {
            let verdict = RollbackProtection.evaluate(profile: profile)
            verdicts[profile.token] = verdict
            if verdict.deservesWarning {
                WegaLog.error(.homebrew,
                              "\(profile.token): brak ochrony rollbackiem — cask nie instaluje aplikacji, nie da się zrobić snapshotu.")
            }
        }
        caskProtection = verdicts
        caskProfiles = Dictionary(profiles.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        // Sizes are a network round-trip per cask; they are not worth paying for until the
        // user asks to see the plan.
        caskSizes = [:]
    }

    /// F2 — the exact commands the upgrade will run, from the same planner call the upgrade
    /// itself uses. If this ever disagrees with execution, it is because someone rebuilt an
    /// argument vector by hand.
    var plannedCommands: [UpdateCommand] {
        UpdatePlanner.commands(for: UpdatePlanner.plan(selectedKeys: selected, allKeys: allItems.map(\.key)))
    }

    /// The casks this run would upgrade, in the order the command lists them.
    var plannedCaskTokens: [String] {
        UpdatePlanner.plan(selectedKeys: selected, allKeys: allItems.map(\.key)).caskNames
    }

    /// F2 — one HEAD per cask, on demand. `brew info --json` has no size field (verified),
    /// and a CDN may withhold `Content-Length`, so "unknown" is a legitimate answer that the
    /// panel shows verbatim rather than guessing a number.
    func probeDownloadSizes() async {
        guard !probingSizes else { return }
        probingSizes = true
        defer { probingSizes = false }

        let probe = DownloadSizeProbe()
        for token in plannedCaskTokens where caskSizes[token] == nil {
            guard let url = caskDownloads[token]?.url else { continue }
            caskSizes[token] = await probe.probe(urlString: url)
        }
    }

    /// M3(b) — the cleanup the scan used to perform silently, now behind the user's consent.
    func cleanUpStaleCasks() async {
        guard let model, !cleaningStaleCasks, !staleCasks.isEmpty else { return }
        cleaningStaleCasks = true
        defer { cleaningStaleCasks = false }

        var removed: [String] = []
        for token in staleCasks {
            if (try? await model.brewService.uninstallCask(token: token, force: true)) != nil {
                removed.append(token)
            } else {
                WegaLog.error(.homebrew, "Nie udało się usunąć nieaktualnego casku: \(token)")
            }
        }
        staleCasks.removeAll { removed.contains($0) }
        WegaLog.info(.homebrew, "Usunięto nieaktualne caski: \(removed.joined(separator: ", "))")
        showBanner(BannerData(variant: .success,
                              title: trf("Usunięto %@ nieaktualnych casków", "\(removed.count)"),
                              message: tr("Homebrew nie śledzi już aplikacji, których nie ma na dysku.")))
    }

    /// The user does not want to clean up now. Drop the card for this scan.
    func dismissStaleCasks() {
        staleCasks = []
    }

    func restartApp(_ info: RestartInfo) async {
        restartBusy = info.processName
        await processes.kill(info.processName)
        try? await Task.sleep(for: .milliseconds(800))
        await processes.launch(appName: info.appName)
        restartCandidates.removeAll { $0.processName == info.processName }
        restartBusy = nil
    }
}
