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

    public func scan(brewOutdatedCasks: Set<String> = []) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        let casks = (try? await CaskDatabaseClient(cache: CaskDatabaseCache(fileURL: caskCacheURL)).fetchCasks()) ?? []
        let installedCasks = (try? await brewService.installedCasks()) ?? []
        // brew-tracked versions (from `brew list --cask --versions`); used as ground truth
        // for brew-managed apps instead of bundle version to avoid versioning scheme mismatches.
        let brewCaskVersions = (try? await brewService.caskVersions()) ?? [:]

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
        var work: [@Sendable () async -> ManualCheckResult] = []
        for app in appsToCheck {
            if let token = app.caskToken {
                let brewTracked = brewCaskVersions[token]
                work.append {
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
                }
            }
            work.append { await jetbrainsChecker.check(app: app) }
            work.append { await githubChecker.check(app: app) }
            work.append { await synologyChecker.check(app: app) }
            work.append { await antigravityChecker.check(app: app) }
            work.append { await parallelsChecker.check(app: app) }
            work.append { await googleDriveChecker.check(app: app) }
            work.append { await chatGPTChecker.check(app: app) }
            // Always run Sparkle: even when an app is matched to an installed cask
            // (e.g. Codex.app vs. cask `codex` which is actually a CLI binary), the
            // app itself may have its own appcast. Priority dedup ensures cask (2)
            // wins over sparkle (1) when both report the same path.
            work.append { await sparkleChecker.check(app: app) }
        }

        var collected: [ManualOutdatedApp] = []
        var failedChecks = 0
        for result in await runBounded(limit: maxConcurrentChecks, work) {
            switch result {
            case .outdated(let item): collected.append(item)
            case .failed:             failedChecks += 1
            case .upToDate, .notApplicable: break
            }
        }
        return (UpdatePlanner.dedupedByPriority(collected), failedChecks)
    }
}
