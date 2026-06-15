import Foundation

/// Runs the manual-app update checkers (Sparkle, JetBrains, GitHub, Synology,
/// Antigravity, Parallels, Google Drive, ChatGPT) plus the brew-cask version check
/// over every installed app, and returns the outdated ones deduplicated by source
/// priority — together with the number of checks that genuinely failed.
///
/// Extracted out of `UpdateView` so the menu-bar agent's background check and the
/// main window share one implementation.
public struct ManualUpdateScanner: Sendable {
    private let brewService: BrewService
    private let scanDirectories: [URL]
    private let caskCacheURL: URL
    private let maxConcurrentChecks: Int

    public init(
        brewService: BrewService = BrewService(),
        scanDirectories: [URL] = AppScanDirectories.all(),
        caskCacheURL: URL = AppScanDirectories.caskDatabaseCacheURL,
        maxConcurrentChecks: Int = 12
    ) {
        self.brewService = brewService
        self.scanDirectories = scanDirectories
        self.caskCacheURL = caskCacheURL
        self.maxConcurrentChecks = maxConcurrentChecks
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
        return {
            let result = await run()
            switch result {
            case .failed:
                WegaLog.error(.network, "\(source) · \(appName): błąd odpowiedzi lub parsowania")
            case .unavailable:
                WegaLog.warning(.network, "\(source) · \(appName): źródło chwilowo niedostępne")
            default:
                break
            }
            return result
        }
    }

    public func scan(brewOutdatedCasks: Set<String> = []) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        let casks = (try? await CaskDatabaseClient(cache: CaskDatabaseCache(fileURL: caskCacheURL)).fetchCasks()) ?? []
        let installedCasks = (try? await brewService.installedCasks()) ?? []
        // brew-tracked versions (from `brew list --cask --versions`); used as ground truth
        // for brew-managed apps instead of bundle version to avoid versioning scheme mismatches.
        // DEBT-05: robust JSON installed-versions (token→version) zamiast kruchego
        // parsowania tekstu `brew list --cask --versions`.
        let brewCaskVersions = (try? await brewService.caskInstalledVersions()) ?? [:]

        // Drop CLI-only casks (e.g. `codex`) from the set we feed to CaskMatcher.
        let installInfo = (try? await brewService.caskInstallationInfo(tokens: Array(installedCasks))) ?? []
        let appProducingTokens: Set<String> = {
            let producers = Set(installInfo.filter { !$0.appArtifacts.isEmpty }.map(\.token))
            // If brew info failed for everything (offline?), don't accidentally hide all matches.
            return producers.isEmpty ? installedCasks : producers
        }()

        let scanner = ApplicationScanner()
        var seen = Set<String>()
        var appsToCheck: [ApplicationInfo] = []
        for dir in scanDirectories {
            let found = (try? scanner.scanApplications(in: dir, installedCasks: appProducingTokens, availableCasks: casks)) ?? []
            for app in found where !app.isManagedByMas {
                if let token = app.caskToken, brewOutdatedCasks.contains(token) { continue }
                let key = app.bundleIdentifier ?? app.path.path
                if seen.insert(key).inserted { appsToCheck.append(app) }
            }
        }

        let sparkleChecker = SparkleUpdateChecker()
        let jetbrainsChecker = JetBrainsUpdateChecker()
        let githubChecker = GitHubReleasesChecker()
        let synologyChecker = SynologyUpdateChecker()
        let antigravityChecker = AntigravityUpdateChecker()
        let parallelsChecker = ParallelsUpdateChecker()
        let googleDriveChecker = GoogleDriveUpdateChecker()
        let chatGPTChecker = ChatGPTUpdateChecker()
        let brew = brewService

        // Build every per-app check as an independent unit of work, then run them with a
        // bounded concurrency cap. An unbounded group would open one connection per
        // (app × checker) — hundreds at once on a large /Applications — and hammer the
        // remote update APIs; the cap keeps the fan-out polite without serialising it.
        // Brew decides for brew-managed apps: `brew outdated` is their single source of
        // truth, so we DON'T run the cask-version check or the cask-lag special checkers
        // on them. Managed status uses the FULL installed-cask set (matched by name or
        // resolved token), so pkg-artifact casks like `google-drive` count too.
        let normalizedInstalledCasks = Set(installedCasks.map { StringNormalizer.normalize($0) })
        func isBrewManaged(_ app: ApplicationInfo) -> Bool {
            if app.isManagedByBrew { return true }
            if let token = app.caskToken,
               normalizedInstalledCasks.contains(StringNormalizer.normalize(token)) { return true }
            return false
        }

        var work: [@Sendable () async -> ManualCheckResult] = []
        for app in appsToCheck {
            if !isBrewManaged(app) {
                // Non-brew apps only: cask-version check (adoption candidates) plus the
                // cask-lag special checkers.
                if let token = app.caskToken {
                    let brewTracked = brewCaskVersions[token]
                    work.append(Self.logged("Cask", app) {
                        guard let latest = await brew.caskLatestVersion(token: token) else { return .upToDate }
                        let reference = brewTracked ?? app.version
                        guard let installed = reference,
                              !versionsEqual(latest, installed),
                              isUpgrade(installed: installed, latest: latest) else { return .upToDate }
                        return .outdated(ManualOutdatedApp(
                            name: app.name, path: app.path,
                            installedVersion: app.version ?? installed,
                            availableVersion: versionVariants(latest).first ?? latest,
                            source: .cask(token: token)
                        ))
                    })
                }
                work.append(Self.logged("JetBrains", app) { await jetbrainsChecker.check(app: app) })
                work.append(Self.logged("GitHub", app) { await githubChecker.check(app: app) })
                work.append(Self.logged("Synology", app) { await synologyChecker.check(app: app) })
                work.append(Self.logged("Antigravity", app) { await antigravityChecker.check(app: app) })
                work.append(Self.logged("Parallels", app) { await parallelsChecker.check(app: app) })
                work.append(Self.logged("Google Drive", app) { await googleDriveChecker.check(app: app) })
                work.append(Self.logged("ChatGPT", app) { await chatGPTChecker.check(app: app) })
            }
            // Sparkle ALWAYS — it's the app's own appcast, independent of Homebrew. Also
            // keeps working for an app that merely shares a name with a CLI-only cask
            // (e.g. Codex.app vs. the `codex` binary cask), which isn't really brew's app.
            work.append(Self.logged("Sparkle", app) { await sparkleChecker.check(app: app) })
        }

        var collected: [ManualOutdatedApp] = []
        var failedChecks = 0
        for result in await runBounded(limit: maxConcurrentChecks, work) {
            switch result {
            case .outdated(let item): collected.append(item)
            case .failed:             failedChecks += 1
            case .unavailable:        break
            case .upToDate, .notApplicable: break
            }
        }
        return (UpdatePlanner.dedupedByPriority(collected), failedChecks)
    }
}
