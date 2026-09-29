import Foundation

/// Runs the 14 manual-app update checkers (Sparkle, JetBrains, GitHub, Synology,
/// Antigravity, Parallels, Google Drive, ChatGPT, Postman, Discord, Signal, Chrome,
/// Obsidian, Adobe Creative Cloud) plus the brew-cask version check
/// over every installed app, and returns the outdated ones deduplicated by source
/// priority — together with source failures, temporary outages and per-installation evidence.
///
/// Extracted out of `UpdateView` so the menu-bar agent's background check and the
/// main window share one implementation.
public struct ManualUpdateScanner: Sendable {
    private let brewService: BrewService
    private let scanDirectories: [URL]
    private let caskCacheURL: URL
    private let maxConcurrentChecks: Int
    private let selfUpdateChecker: WegaSelfUpdateChecker
    private let rollbackLedger: CaskRollbackLedger
    private let javaRuntimeScanner: JavaRuntimeScanner
    private let javaRuntimeDirectories: [URL]
    private let packageReceiptLocator: PackageReceiptLocator
    private let adobeCatalogClient: AdobeCatalogClient
    private let adobeUninstallDirectory: URL
    private let sparkleChecker: SparkleUpdateChecker

    public init(
        brewService: BrewService = BrewService(),
        scanDirectories: [URL] = AppScanDirectories.all(configuration: ScanConfigurationStore.resolvedConfiguration()),
        caskCacheURL: URL = AppScanDirectories.caskDatabaseCacheURL,
        maxConcurrentChecks: Int = 12,
        selfUpdateChecker: WegaSelfUpdateChecker = WegaSelfUpdateChecker(),
        rollbackLedger: CaskRollbackLedger = .shared,
        javaRuntimeScanner: JavaRuntimeScanner = JavaRuntimeScanner(),
        javaRuntimeDirectories: [URL] = JavaRuntimeScanner.scanDirectories(),
        packageReceiptLocator: PackageReceiptLocator = PackageReceiptLocator(),
        adobeCatalogClient: AdobeCatalogClient = .productCatalog(),
        adobeUninstallDirectory: URL = SystemPaths.adobeUninstallDirectory,
        sparkleChecker: SparkleUpdateChecker = SparkleUpdateChecker()
    ) {
        self.brewService = brewService
        self.scanDirectories = scanDirectories
        self.caskCacheURL = caskCacheURL
        self.maxConcurrentChecks = maxConcurrentChecks
        self.selfUpdateChecker = selfUpdateChecker
        self.rollbackLedger = rollbackLedger
        self.javaRuntimeScanner = javaRuntimeScanner
        self.javaRuntimeDirectories = javaRuntimeDirectories
        self.packageReceiptLocator = packageReceiptLocator
        self.adobeCatalogClient = adobeCatalogClient
        self.adobeUninstallDirectory = adobeUninstallDirectory
        self.sparkleChecker = sparkleChecker
    }

    /// UX-15 — Wega dogfoods its own update path. A self-update maps to the same
    /// ``ManualOutdatedApp`` every vendor produces, so it rides one chokepoint (this scanner)
    /// into the count, the badge, the notification and the Updates window's manual section —
    /// "one count, everywhere". Returns `nil` when the app is current or the check failed.
    ///
    /// Pure and parameterised (no `Bundle`/network) so the mapping is unit-tested directly;
    /// `scan()` feeds it the running app's identity.
    static func selfUpdateApp(
        from result: WegaSelfUpdateChecker.Result,
        appPath: URL,
        installedVersion: String,
        bundleIdentifier: String?
    ) -> ManualOutdatedApp? {
        guard case let .updateAvailable(version, _, releaseURL, notes) = result else { return nil }
        return ManualOutdatedApp(
            name: "Wega",
            path: appPath,
            installedVersion: installedVersion,
            availableVersion: version,
            source: .wega(releaseURL: releaseURL),
            origin: .manual,
            releaseNotes: ReleaseNotes(html: notes, version: version),
            bundleIdentifier: bundleIdentifier
        )
    }

    /// Opakowuje check tak, by zalogować, które źródło dla której aplikacji
    /// zamilkło: `.failed` na poziomie ERROR (prawdziwy błąd), `.unavailable` na
    /// poziomie WARNING (chwilowa niedostępność źródła — nie nasz problem).
    /// `runBounded` nie zachowuje kolejności wyników, więc logujemy tutaj,
    /// w domknięciu, gdzie etykieta jest w zasięgu.
    static func logged(
        _ source: String,
        _ app: ApplicationInfo,
        _ run: @escaping @Sendable () async -> ManualCheckResult
    ) -> @Sendable () async -> ManualCheckResult {
        let appName = app.name
        // One chokepoint for stamping install origin onto every outdated result, using
        // the SAME classifier the Inventory window uses for its badge. Grouping the
        // Updates window by this origin (rather than by update source) is what keeps a
        // Homebrew cask like Docker/Postman labelled "Brew" in both windows instead of
        // showing up under "Ręcznie zainstalowane" in one of them.
        let origin = AppOrigin.of(app)
        // REL-11: stamp the scanned app's bundle identifier onto every outdated result
        // at the same chokepoint as `origin`, so the policy key (`bundle ID + path`) is
        // consistent regardless of which checker produced the result.
        let bundleIdentifier = app.bundleIdentifier
        return {
            let start = Date()
            let result = await run()
            let millis = Int(Date().timeIntervalSince(start) * 1000)
            switch result {
            case .failed:
                WegaLog.error(.network, "\(source) · \(appName): błąd odpowiedzi lub parsowania")
            case .unavailable:
                WegaLog.warning(.network, "\(source) · \(appName): źródło chwilowo niedostępne")
            default:
                break
            }
            // Per-checker diagnostics (DEBUG): only checks that actually engaged a source
            // (up-to-date / outdated, with timing) — `.notApplicable` is silent, and
            // failures are already logged at warning/error above.
            if let dbg = ScanLog.checkerDebugLine(source: source, app: appName, result: result, millis: millis) {
                WegaLog.debug(.scanner, dbg)
            }
            if case .outdated(var item) = result {
                item.origin = origin
                item.bundleIdentifier = bundleIdentifier
                return .outdated(item)
            }
            return result
        }
    }

    static func observed(
        _ source: String, _ app: ApplicationInfo, checker: some VendorUpdateChecker
    ) -> @Sendable () async -> ManualCheckObservation {
        return {
            let plan = checker.plan(for: app)
            let check = logged(source, app) { await checker.check(app: app, plan: plan) }
            return ManualCheckObservation(app: app, source: source, result: await check(), wasApplicable: plan != nil)
        }
    }

    static func observed(
        _ source: String, _ app: ApplicationInfo, applicable: Bool = false,
        _ run: @escaping @Sendable () async -> ManualCheckResult
    ) -> @Sendable () async -> ManualCheckObservation {
        let check = logged(source, app, run)
        return { ManualCheckObservation(app: app, source: source, result: await check(), wasApplicable: applicable) }
    }

    /// The "Homebrew knows a newer version than the bundle on disk" check, for one app that
    /// brew does not already own.
    ///
    /// Shared by the `.app` fan-out and the JDK one — the two lists differ in how their
    /// members are discovered and in which vendor checkers apply to them, but this comparison
    /// is identical, and duplicating it is how the two would drift apart. Returns `nil` for an
    /// app no cask matches, so a machine full of unpackaged apps queues no no-op work.
    static func caskVersionCheck(
        app: ApplicationInfo,
        brewTrackedVersion: String?,
        latestCaskVersions: [String: String]
    ) -> (@Sendable () async -> ManualCheckObservation)? {
        guard let token = app.caskToken else { return nil }
        return Self.observed("Cask", app, applicable: true) {
            guard let latest = latestCaskVersions[token] else { return .unavailable }
            let reference = brewTrackedVersion ?? app.version
            guard let installed = reference, !installed.isEmpty else { return .notApplicable }
            if versionsEqual(latest, installed) { return .upToDate }
            guard compareVersions(installed, latest, scheme: .buildNumbered) != .unknown else { return .failed }
            guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }
            return .outdated(ManualOutdatedApp(
                name: app.name, path: app.path,
                installedVersion: app.version ?? installed,
                availableVersion: versionVariants(latest).first ?? latest,
                source: .cask(token: token)
            ))
        }
    }

    /// Installed Java runtimes, each carrying the cask token its installer receipt resolves to.
    ///
    /// A runtime with no receipt (unpacked from an archive) or one no cask claims is dropped:
    /// without a token there is no source that could say whether it is current, and a row with
    /// no available version and no action would be noise rather than information.
    private func javaRuntimesWithCaskTokens(
        casks: [BrewCask],
        brewOutdatedCasks: Set<String>
    ) async -> [ApplicationInfo] {
        let runtimes = javaRuntimeScanner.scanAll(directories: javaRuntimeDirectories)
        guard !runtimes.isEmpty else { return [] }
        let receiptIndex = CaskPackageReceiptIndex(casks: casks)

        var resolved: [ApplicationInfo] = []
        for var runtime in runtimes {
            guard runtime.version != nil,
                  let packageID = await packageReceiptLocator.packageIdentifier(forBundleAt: runtime.path),
                  let token = receiptIndex.token(forPackageIdentifier: packageID),
                  // `brew outdated` already reports this one; a second row would double-count it.
                  !brewOutdatedCasks.contains(token) else { continue }
            runtime.caskToken = token
            resolved.append(runtime)
        }
        return resolved
    }

    public func scan(brewOutdatedCasks: Set<String> = []) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        let report = await scanReport(brewOutdatedCasks: brewOutdatedCasks)
        return (report.apps, report.failedChecks)
    }

    public func scanReport(brewOutdatedCasks: Set<String> = []) async -> ManualScanReport {
        var uncheckedSources: [String] = []
        var brewAvailable = true
        func read<Value: Sendable>(source: String, fallback: Value, _ load: () async throws -> Value) async -> Value {
            do { return try await load() }
            catch BrewServiceError.brewNotFound { brewAvailable = false; return fallback }
            catch {
                if !Task.isCancelled {
                    uncheckedSources.append(source)
                    WegaLog.warning(.scanner, "\(source): \(error.localizedDescription)")
                }
                return fallback
            }
        }
        let casks = await read(source: "Homebrew catalog", fallback: [BrewCask]()) {
            try await CaskDatabaseClient.caskCatalog(cacheURL: caskCacheURL).fetchCasks()
        }
        let installedCasks = await read(source: "Homebrew casks", fallback: Set<String>()) {
            try await brewService.installedCasks()
        }
        // brew-tracked versions (from `brew list --cask --versions`); used as ground truth
        // for brew-managed apps instead of bundle version to avoid versioning scheme mismatches.
        // DEBT-05: robust JSON installed-versions (token→version) zamiast kruchego
        // parsowania tekstu `brew list --cask --versions`.
        let brewCaskVersions = await read(source: "Homebrew versions", fallback: [String: String]()) {
            try await brewService.caskInstalledVersions()
        }

        // Drop CLI-only casks (e.g. `codex`) from the set we feed to CaskMatcher.
        let installInfo = await read(source: "Homebrew installation paths", fallback: [BrewCaskInstallationInfo]()) {
            try await brewService.caskInstallationInfo(tokens: Array(installedCasks))
        }
        let caskPaths = CaskAppPathResolver().appPaths(from: installInfo)
        let appProducingTokens: Set<String> = {
            let producers = Set(installInfo.filter { !$0.appArtifacts.isEmpty }.map(\.token))
            // If brew info failed for everything (offline?), don't accidentally hide all matches.
            return producers.isEmpty ? installedCasks : producers
        }()

        let scanner = ApplicationScanner()
        var seen = Set<InstallationIdentity>()
        var appsToCheck: [ApplicationInfo] = []
        for dir in scanDirectories {
            let found = await read(source: dir.path, fallback: [ApplicationInfo]()) {
                do { return try scanner.scanApplications(in: dir, installedCasks: appProducingTokens, availableCasks: casks) }
                catch CocoaError.fileReadNoSuchFile { return [] }
            }
            for app in found {
                if seen.insert(app.installation).inserted { appsToCheck.append(app) }
            }
        }
        let allInstallations = Self.routeDistinctInstallations(appsToCheck, caskAppPaths: caskPaths, brewOutdatedCasks: [])
        appsToCheck = Self.routeDistinctInstallations(
            allInstallations.filter { !$0.isManagedByMas }, caskAppPaths: caskPaths, brewOutdatedCasks: brewOutdatedCasks
        )

        // JDKs live outside every Applications root and are not `.app` bundles, so the scan
        // above cannot see them; they are resolved to a cask through their installer receipt
        // and then compared by the same cask check every adoption candidate goes through.
        // Kept in their own list because none of the vendor checkers apply to a runtime —
        // there is no appcast, no JetBrains code and no GitHub repo to ask.
        let javaRuntimes = await javaRuntimesWithCaskTokens(casks: casks, brewOutdatedCasks: brewOutdatedCasks)
            .filter { seen.insert($0.installation).inserted }

        // One catalog and one inventory read for the whole scan (see `AdobeUpdateChecker`).
        let adobeInventory = AdobeProductInventory.installedProducts(in: adobeUninstallDirectory)
        var adobeChecker: AdobeUpdateChecker?
        if !adobeInventory.isEmpty {
            let catalog = await read(source: "Adobe catalog", fallback: AdobeProductCatalog()) {
                try await adobeCatalogClient.fetchCatalog()
            }
            adobeChecker = AdobeUpdateChecker(catalog: catalog, inventory: adobeInventory)
        }

        let sparkleChecker = self.sparkleChecker
        let jetbrainsChecker = JetBrainsUpdateChecker()
        let githubChecker = GitHubReleasesChecker()
        let synologyChecker = SynologyUpdateChecker()
        let antigravityChecker = AntigravityUpdateChecker()
        let parallelsChecker = ParallelsUpdateChecker()
        let googleDriveChecker = GoogleDriveUpdateChecker()
        let chatGPTChecker = ChatGPTUpdateChecker()
        let postmanChecker = PostmanUpdateChecker()
        let discordChecker = DiscordUpdateChecker()
        let signalChecker = SignalUpdateChecker()
        let chromeChecker = ChromeUpdateChecker()
        let obsidianChecker = ObsidianUpdateChecker()
        let brew = brewService

        // Build every per-app check as an independent unit of work, then run them with a
        // bounded concurrency cap. An unbounded group would open one connection per
        // (app × checker) — hundreds at once on a large /Applications — and hammer the
        // remote update APIs; the cap keeps the fan-out polite without serialising it.
        // Brew decides for brew-managed apps: `brew outdated` is their single source of
        // truth, so we DON'T run the cask-version check or the cask-lag special checkers
        // on them. Managed status uses the FULL installed-cask set (matched by name or
        // resolved token), so pkg-artifact casks like `google-drive` count too.
        // Brew is the source of truth for an app only when it actually tracks an
        // installed version for the cask. A cask listed by `brew list --cask` but with
        // no version in `brew info --installed` (empty Caskroom metadata — e.g. Claude,
        // Postman, which self-updated out-of-band) is invisible to `brew outdated`, so
        // route it to the cask-version check below instead of deferring to brew.
        let brewTrackedTokens = Set(brewCaskVersions.keys)
        func isBrewManaged(_ app: ApplicationInfo) -> Bool {
            BrewManagement.isAuthoritative(
                caskToken: app.caskToken,
                isManagedByBrew: app.isManagedByBrew,
                installedCaskTokens: installedCasks,
                brewTrackedTokens: brewTrackedTokens
            )
        }

        // ARCH-05a: one `brew info` for every adoption candidate, resolved before the fan-out,
        // instead of one process per app inside it. Each of those calls re-read the same cask
        // database to answer about a single token.
        let candidateTokens = (appsToCheck.filter { !isBrewManaged($0) } + javaRuntimes)
            .compactMap(\.caskToken)
        let latestCaskVersions = await brew.caskLatestVersions(tokens: Array(Set(candidateTokens)))

        var work: [@Sendable () async -> ManualCheckObservation] = []
        for runtime in javaRuntimes where brewAvailable && !isBrewManaged(runtime) {
            if let check = Self.caskVersionCheck(
                app: runtime,
                brewTrackedVersion: runtime.caskToken.flatMap { brewCaskVersions[$0] },
                latestCaskVersions: latestCaskVersions
            ) {
                work.append(check)
            }
        }
        for app in appsToCheck {
            if !isBrewManaged(app) {
                // Non-brew apps only: cask-version check (adoption candidates) plus the
                // cask-lag special checkers.
                if brewAvailable, let check = Self.caskVersionCheck(
                    app: app,
                    brewTrackedVersion: app.caskToken.flatMap { brewCaskVersions[$0] },
                    latestCaskVersions: latestCaskVersions
                ) {
                    work.append(check)
                }
                if let adobeChecker {
                    work.append(Self.observed("Adobe", app) { adobeChecker.check(app: app) })
                }
                work.append(Self.observed("JetBrains", app, checker: jetbrainsChecker))
                work.append(Self.observed("GitHub", app, checker: githubChecker))
                work.append(Self.observed("Synology", app, checker: synologyChecker))
                work.append(Self.observed("Antigravity", app, checker: antigravityChecker))
                work.append(Self.observed("Parallels", app, checker: parallelsChecker))
                work.append(Self.observed("Google Drive", app, checker: googleDriveChecker))
                work.append(Self.observed("ChatGPT", app, checker: chatGPTChecker))
                work.append(Self.observed("Postman", app, checker: postmanChecker))
                work.append(Self.observed("Discord", app, checker: discordChecker))
                work.append(Self.observed("Signal", app, checker: signalChecker))
                work.append(Self.observed("Chrome", app, checker: chromeChecker))
            }
            // Obsidian self-updates its ASAR package independently of its installer.
            // Run this even when Homebrew owns the current cask: brew may correctly report
            // the installer as current while an insider package update is still available.
            if app.bundleIdentifier == ObsidianUpdateChecker.bundleIdentifier {
                work.append(Self.observed("Obsidian", app, checker: obsidianChecker))
            }
            // Sparkle ALWAYS — it's the app's own appcast, independent of Homebrew. Also
            // keeps working for an app that merely shares a name with a CLI-only cask
            // (e.g. Codex.app vs. the `codex` binary cask), which isn't really brew's app.
            work.append(Self.observed("Sparkle", app, checker: sparkleChecker))
        }

        var observations = await runBounded(limit: maxConcurrentChecks, work)
        let selfResult = await selfUpdateChecker.check()
        let selfApp = allInstallations.first { $0.installation == InstallationIdentity(path: Bundle.main.bundleURL) } ?? ApplicationInfo(
            path: Bundle.main.bundleURL, name: "Wega", bundleIdentifier: AppMetadata.bundleIdentifier,
            version: AppMetadata.version, buildVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            installDate: nil, updateDate: nil, isManagedByBrew: false, caskToken: nil
        )
        let selfUpdate = Self.selfUpdateApp(from: selfResult, appPath: selfApp.path,
                                           installedVersion: AppMetadata.version, bundleIdentifier: AppMetadata.bundleIdentifier)
        observations.append(ManualCheckObservation(app: selfApp, source: "GitHub",
                                                  result: selfUpdate.map { .outdated($0) } ?? (selfResult == .failed ? .failed : .upToDate)))
        var collected = observations.compactMap { observation -> ManualOutdatedApp? in
            if case .outdated(let item) = observation.result { return item }
            return nil
        }
        // REL-07 — force any auto-rolled-back cask back onto the list. `brew outdated` no longer
        // reports it (its Caskroom records the new version) and it is brew-managed, so both the
        // brew list and the cask-version check above skip it; without this the reverted version
        // silently vanishes from every scan until upstream ships something newer.
        // REL-07 follow-up — a mark for a cask the user has since uninstalled has nothing left
        // to force onto the list, and `rolledBackRows` silently skips it, so it would sit in
        // `UserDefaults` for good. Pruned from brew's own installed list, which stays
        // authoritative for a rolled-back cask: its Caskroom entry survives the rollback.
        rollbackLedger.prune(installedCaskTokens: Set(brewCaskVersions.keys))
        func listedCaskTokens() -> Set<String> {
            brewOutdatedCasks.union(collected.compactMap { app -> String? in
                if case .cask(let token) = app.source { return token }
                return nil
            })
        }
        collected.append(contentsOf: Self.rolledBackRows(
            rolledBackTokens: rollbackLedger.rolledBackTokens(),
            installedApps: appsToCheck + javaRuntimes,
            brewCaskVersions: brewCaskVersions,
            alreadyListedTokens: listedCaskTokens()
        ))
        // REL-17 — the last gap where a pending update is visible to nobody: brew's Caskroom
        // records a version the bundle on disk never reached, so `brew outdated` (receipt vs
        // cask) stays silent while `isBrewManaged` has already suppressed both the
        // cask-version check and every vendor checker for that app.
        collected.append(contentsOf: Self.caskMetadataDriftRows(
            installedApps: appsToCheck + javaRuntimes,
            brewCaskVersions: brewCaskVersions,
            alreadyListedTokens: listedCaskTokens()
        ))
        return Self.makeReport(
            collected: collected, observations: observations, installations: allInstallations + javaRuntimes + [selfApp],
            brewOwnership: BrewOwnership(paths: caskPaths, tracked: brewTrackedTokens.union(brewOutdatedCasks), available: brewAvailable),
            uncheckedSources: uncheckedSources
        )
    }

    private struct BrewOwnership {
        let paths: [String: URL]
        let tracked: Set<String>
        let available: Bool
    }

    private static func makeReport(
        collected: [ManualOutdatedApp], observations: [ManualCheckObservation], installations: [ApplicationInfo],
        brewOwnership: BrewOwnership, uncheckedSources: [String]
    ) -> ManualScanReport {
        let apps = InstallationInventory.deduplicated(installations)
        var report = ManualScanReport(apps: UpdatePlanner.dedupedByPriority(collected), observations: observations,
                                      installations: apps, checkedAt: Date())
        report.failedChecks += uncheckedSources.count
        report.uncheckedSources = (report.uncheckedSources + uncheckedSources).sorted()
        report.installations = zip(apps, report.installations).map { app, check in
            var record = check
            if let token = app.caskToken, brewOwnership.tracked.contains(token),
               brewOwnership.paths[token].map({ InstallationIdentity(path: $0) }) == app.installation {
                record.caskToken = token
                record.sources.append(.init(source: "Homebrew", outcome: .notChecked))
            } else if app.isManagedByBrew || (!brewOwnership.available && app.caskToken != nil && record.sources.isEmpty) {
                record.sources.append(.init(source: "Homebrew", outcome: .notChecked))
            }
            if app.isManagedByMas { record.sources.append(.init(source: "App Store", outcome: .notChecked)) }
            if !uncheckedSources.isEmpty { record.sources.append(.init(source: "Dane skanowania", outcome: .failed)) }
            // Forced rollback/drift rows are evidence too, even when no vendor reported an update.
            for update in report.apps where InstallationIdentity(path: update.path) == app.installation {
                let source = InstallationSourceCheck(source: "Wega", result: .outdated(update))
                if !record.sources.contains(where: { $0.outcome == .outdated && $0.policyKey == source.policyKey }) {
                    record.sources.append(source)
                }
            }
            record.lastSuccessfulCheck = nil
            record.stampSuccess()
            return record
        }
        return report
    }

    /// Multiple copies may share a cask match, but only its resolved target can inherit Brew's
    /// version or install action. The other copies continue through their own vendor feeds.
    static func routeDistinctInstallations(
        _ apps: [ApplicationInfo], caskAppPaths: [String: URL], brewOutdatedCasks: Set<String>
    ) -> [ApplicationInfo] {
        var copyCounts: [String: Int] = [:]
        for app in apps {
            if let token = app.caskToken { copyCounts[token, default: 0] += 1 }
        }
        return apps.compactMap { app in
            var routed = app
            if let token = app.caskToken, copyCounts[token, default: 0] > 1,
               caskAppPaths[token].map({ InstallationIdentity(path: $0) }) != app.installation {
                routed.caskToken = nil
                routed.caskMatchProvenance = nil
                routed.isManagedByBrew = false
            }
            if let token = routed.caskToken, brewOutdatedCasks.contains(token) { return nil }
            return routed
        }
    }

    /// REL-07 — synthesises the forced list rows for casks a prior auto-rollback reverted.
    ///
    /// `brew outdated` no longer reports these (its Caskroom records the new version), so the
    /// normal path drops them. For each still-installed rolled-back token brew isn't already
    /// listing, this produces one `.cask` row marked `rolledBack` — showing the version actually
    /// on disk against the one brew's metadata claims — so a scan can never present the reverted
    /// app as current. The `.cask` source routes the row's Brew action through the ordinary
    /// force-reinstall path, which is the conscious retry that repairs the metadata. Pure and
    /// deterministically ordered so the list does not reshuffle between scans.
    public static func rolledBackRows(
        rolledBackTokens: Set<String>,
        installedApps: [ApplicationInfo],
        brewCaskVersions: [String: String],
        alreadyListedTokens: Set<String>
    ) -> [ManualOutdatedApp] {
        let appByToken = Dictionary(
            installedApps.compactMap { app in app.caskToken.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        return rolledBackTokens
            .subtracting(alreadyListedTokens)
            .sorted()
            .compactMap { token in
                guard let app = appByToken[token] else { return nil }
                return ManualOutdatedApp(
                    name: app.name,
                    path: app.path,
                    installedVersion: app.version,
                    availableVersion: brewCaskVersions[token],
                    source: .cask(token: token),
                    origin: AppOrigin.of(app),
                    bundleIdentifier: app.bundleIdentifier,
                    rolledBack: true
                )
            }
    }

    /// REL-17 — synthesises rows for casks whose Homebrew metadata drifted *ahead* of the app
    /// actually on disk.
    ///
    /// ``BrewCaskDriftFilter`` covers the opposite direction — bundle at or past
    /// `current_version` while brew's record lags — and hides those as false positives. This is
    /// the false *negative*: an install that never landed, or a bundle replaced out-of-band with
    /// an older one, leaves brew's Caskroom claiming a version the disk never reached. Brew then
    /// compares its own receipt against the cask, finds them equal, and reports nothing; because
    /// brew tracks a version, ``BrewManagement/isAuthoritative(caskToken:isManagedByBrew:installedCaskTokens:brewTrackedTokens:)``
    /// makes it the sole source of truth and `scan()` runs neither the cask-version check nor any
    /// vendor checker on that app. Nothing compares the bundle against the cask, so the update is
    /// invisible everywhere.
    ///
    /// Discord is the reproducer: brew records `0.0.403`, `/Applications/Discord.app` is
    /// `0.0.402`, and Discord's own Squirrel feed answers 204 for `0.0.402` — so even running the
    /// vendor checker would report it current. Homebrew's metadata is the only source that knows.
    ///
    /// The row carries the `.cask` source, whose action force-reinstalls and thereby repairs the
    /// Caskroom record in the same pass. It is deliberately *not* marked `rolledBack`: no rollback
    /// happened, so the REL-07 "cofnięto — ponów próbę" label would misstate the cause while the
    /// remedy is already identical.
    ///
    /// Drift is judged with the tolerant `.buildNumbered` scheme, so a build suffix on only one
    /// side (Homebrew's `5.3.1,50301` against a bare `5.3.1`) is encoding noise rather than a
    /// phantom row, and an unparseable version yields no row at all. Pure and deterministically
    /// ordered so the list does not reshuffle between scans.
    ///
    /// ``isAlreadyAtRecordedVersion(app:recorded:)`` runs first and is what keeps an app that is
    /// merely *written* differently from being reported as behind — the failure this detector
    /// shipped with, which pinned a current Zoom (`7.1.5 (84650)` against the Caskroom's
    /// `7.1.5.84650`) and a current Google Drive to the list permanently, and sent every retry
    /// into an adoption that could not succeed.
    /// Whether the bundle already *is* the version brew recorded, in either of the two
    /// strings it publishes.
    ///
    /// Both halves are load-bearing, and for different reasons. `versionsEqual` on the
    /// short string is the same tie-break the ordinary cask-version check has always
    /// applied before `isUpgrade` (see `scan()`); this detector consulted only `isUpgrade`
    /// and so had no defence when the two disagreed. `CFBundleVersion` covers the case no
    /// comparator can reach: Google Drive's short string is a genuinely *shorter* version
    /// (`129.0` against Homebrew's `129.0.1`), and only the build string proves they are
    /// the same install.
    private static func isAlreadyAtRecordedVersion(app: ApplicationInfo, recorded: String) -> Bool {
        [app.version, app.buildVersion]
            .compactMap { $0 }
            .contains { versionsEqual($0, recorded) }
    }

    public static func caskMetadataDriftRows(
        installedApps: [ApplicationInfo],
        brewCaskVersions: [String: String],
        alreadyListedTokens: Set<String>
    ) -> [ManualOutdatedApp] {
        let appByToken = Dictionary(
            installedApps.compactMap { app in app.caskToken.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        return Set(appByToken.keys)
            .subtracting(alreadyListedTokens)
            .sorted()
            .compactMap { token in
                guard let app = appByToken[token],
                      let recorded = brewCaskVersions[token],
                      let onDisk = app.version,
                      !isAlreadyAtRecordedVersion(app: app, recorded: recorded),
                      isUpgrade(installed: onDisk, latest: recorded) else { return nil }
                return ManualOutdatedApp(
                    name: app.name,
                    path: app.path,
                    installedVersion: onDisk,
                    availableVersion: recorded,
                    source: .cask(token: token),
                    origin: AppOrigin.of(app),
                    bundleIdentifier: app.bundleIdentifier
                )
            }
    }
}
