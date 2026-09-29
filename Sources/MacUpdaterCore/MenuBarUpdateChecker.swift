import Foundation

/// The **full** result of a menu-bar background check: the raw per-source outdated
/// lists (`brew`/`mas`/`npm`) and the manual-scan result (`manualApps` + `failedChecks`),
/// plus the policy-filtered badge `total` and a `scannedAt` timestamp.
///
/// The background check already builds all of these lists to arrive at the count, so
/// carrying them out (instead of discarding them) lets the app window render the result
/// immediately rather than re-scanning from zero. `total` and `failedChecks` are stored
/// so existing count-only callers (`MenuBarAgent`) keep working unchanged.
public struct MenuBarScanResult: Equatable, Sendable {
    /// Raw `brew outdated` result (formulae + casks), or `nil` when brew is not
    /// installed or its check errored.
    public var brew: BrewOutdated?
    /// Raw Mac App Store outdated apps (empty when `mas` is not installed).
    public var mas: [MasOutdatedApp]
    /// Raw npm global outdated packages (empty when `npm` is not installed).
    public var npm: [NpmGlobalOutdated]
    /// Manual-scan apps (Sparkle/JetBrains/GitHub/cask-lag…), deduped by source
    /// priority. Carried **raw** — policy filtering is reflected only in `total`.
    public var manualApps: [ManualOutdatedApp]
    /// Number of source checks that genuinely failed. A source merely being *not
    /// installed* (brew/mas/npm absent) is **not** counted here.
    public var failedChecks: Int
    /// When the scan completed.
    public var scannedAt: Date
    /// Policy-filtered badge count: package items (ignore/pin honoured) plus visible
    /// manual updates.
    public var total: Int
    public var installationChecks: [InstallationCheck]
    public var sources: ScanSourceReports

    public init(
        brew: BrewOutdated?,
        mas: [MasOutdatedApp],
        npm: [NpmGlobalOutdated],
        manualApps: [ManualOutdatedApp],
        failedChecks: Int,
        scannedAt: Date,
        total: Int,
        installationChecks: [InstallationCheck] = [],
        sources: ScanSourceReports = ScanSourceReports()
    ) {
        self.brew = brew
        self.mas = mas
        self.npm = npm
        self.manualApps = manualApps
        self.failedChecks = failedChecks
        self.scannedAt = scannedAt
        self.total = total
        self.installationChecks = installationChecks
        self.sources = sources
    }

    /// UX-11g — the display names of everything this check found outdated, so the menu-bar
    /// dropdown can say *which* apps have updates instead of only *how many*.
    ///
    /// Built from the same two lists, in the same order and under the same ignore/pin
    /// rules, that produce the badge `total`: the policy-filtered package items (formulae,
    /// casks, App Store, npm) followed by the policy-filtered manual apps. For a result the
    /// checker produced this list therefore has exactly `total` entries, so the names can
    /// never disagree with the count shown beside them.
    public func outdatedDisplayNames(policies: [String: UpdatePolicy] = [:]) -> [String] {
        let items = UpdatePlanner.applyPolicies(
            UpdatePlanner.outdatedItems(brew: brew, mas: mas, npm: npm),
            policies: policies
        )
        let manual = UpdatePlanner.applyPolicies(manualApps, policies: policies)
        return items.map(\.name) + manual.map(\.name)
    }

    /// ARCH-08c: the same result with the casks a background round upgraded taken out, and the
    /// badge recounted from what is left.
    ///
    /// The agent used to run a *second* full scan after a background upgrade — brew, mas, npm
    /// and every manual checker — purely to refresh the badge, even though the only thing that
    /// had changed was a handful of casks it had just upgraded itself. On a menu-bar app that
    /// stays resident, that is a second fan-out of processes and network probes per round, for
    /// information already in hand.
    ///
    /// Only the cask list is touched: upgrading a cask cannot change what `mas`, `npm` or the
    /// vendor checkers would report, so re-deriving those would only reproduce what is here.
    public func removingUpgradedCasks(
        _ upgraded: [String],
        policies: [String: UpdatePolicy] = [:]
    ) -> MenuBarScanResult {
        guard !upgraded.isEmpty, let brew else { return self }
        let done = Set(upgraded)
        var trimmed = self
        trimmed.installationChecks.removeAll { check in check.caskToken.map(done.contains) ?? false }
        trimmed.brew = BrewOutdated(
            formulae: brew.formulae,
            casks: brew.casks.filter { !done.contains($0.name) }
        )
        let items = UpdatePlanner.applyPolicies(
            UpdatePlanner.outdatedItems(brew: trimmed.brew, mas: mas, npm: npm),
            policies: policies
        )
        let visibleManual = UpdatePlanner.applyPolicies(manualApps, policies: policies)
        trimmed.total = items.count + visibleManual.count
        return trimmed
    }
}

// MARK: - Injection seams

/// The single brew call the menu-bar check needs. `BrewService` conforms; tests
/// inject a fake so the check runs without a real Homebrew.
public protocol BrewOutdatedProviding: Sendable {
    func outdatedGreedy() async throws -> BrewOutdated
}

/// The single mas call the menu-bar check needs.
public protocol MasOutdatedProviding: Sendable {
    func outdated() async throws -> [MasOutdatedApp]
}

/// The single npm call the menu-bar check needs.
public protocol NpmOutdatedProviding: Sendable {
    func outdated() async throws -> [NpmGlobalOutdated]
}

/// The manual-scan seam. `ManualUpdateScanner` conforms.
public protocol ManualScanning: Sendable {
    func scan(brewOutdatedCasks: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int)
    func scanReport(brewOutdatedCasks: Set<String>) async -> ManualScanReport
}

public extension ManualScanning {
    func scanReport(brewOutdatedCasks: Set<String>) async -> ManualScanReport {
        let result = await scan(brewOutdatedCasks: brewOutdatedCasks)
        return ManualScanReport(apps: result.apps, failedChecks: result.failedChecks)
    }
}

extension BrewService: BrewOutdatedProviding {}
extension MasService: MasOutdatedProviding {}
extension NpmGlobalService: NpmOutdatedProviding {}
extension ManualUpdateScanner: ManualScanning {}

/// A **read-only** count of available updates for the menu-bar badge and notifications.
/// Unlike the main Update screen it never mutates the system — no `brew update`, no
/// stale-cask cleanup — so it's safe to run silently on a timer.
public struct MenuBarUpdateChecker: Sendable {
    private let brewService: BrewOutdatedProviding
    private let masService: MasOutdatedProviding
    private let npmService: NpmOutdatedProviding
    private let scanner: ManualScanning
    private let operations: OperationCoordinator

    /// Note on `scanner`: it no longer inherits the injected `brewService`, because that
    /// parameter is now a protocol and `ManualUpdateScanner` wants the concrete type. In
    /// production both end up with an identically-configured `BrewService` (its dependencies
    /// are all defaulted `let`s), but a test that fakes `brewService` must fake `scanner`
    /// too — they are two seams now, not one.
    public init(
        brewService: BrewOutdatedProviding = BrewService(),
        masService: MasOutdatedProviding = MasService(),
        npmService: NpmOutdatedProviding = NpmGlobalService(),
        scanner: ManualScanning = ManualUpdateScanner(),
        operations: OperationCoordinator = .shared
    ) {
        self.brewService = brewService
        self.masService = masService
        self.npmService = npmService
        self.scanner = scanner
        self.operations = operations
    }

    public func availableUpdateCount(policies: [String: UpdatePolicy] = [:]) async -> MenuBarScanResult {
        do {
            return try await operations.withReadLease(label: "menu-bar scan") { _ in
                await availableUpdateCountCoordinated(policies: policies)
            }
        } catch {
            WegaLog.error(.helper, "Skan wstrzymany: \(error.localizedDescription)")
            return MenuBarScanResult(
                brew: nil,
                mas: [],
                npm: [],
                manualApps: [],
                failedChecks: 1,
                scannedAt: Date(),
                total: 0
            )
        }
    }

    private func availableUpdateCountCoordinated(
        policies: [String: UpdatePolicy]
    ) async -> MenuBarScanResult {
        var failed = 0
        var reports = ScanSourceReports()

        // F4 — brew missing is "not applicable", exactly as for mas and npm below. Counting
        // it as a failure made the background badge permanently red on machines without it.
        var brew: BrewOutdated?
        do { brew = try await brewService.outdatedGreedy(); reports.brew = ScanSourceReport(outcome: .succeeded) }
        catch BrewServiceError.brewNotFound { reports.brew = ScanSourceReport(outcome: .notInstalled) }
        catch {
            failed += 1
            reports.brew = ScanSourceReport(outcome: .failed("Homebrew"))
            WegaLog.error(.homebrew, "Skan z paska menu — brew outdated: \(error.localizedDescription)")
        }

        var mas: [MasOutdatedApp] = []
        do { mas = try await masService.outdated(); reports.mas = ScanSourceReport(outcome: .succeeded) }
        catch MasServiceError.masNotFound { reports.mas = ScanSourceReport(outcome: .notInstalled) }
        catch {
            failed += 1
            reports.mas = ScanSourceReport(outcome: .failed("App Store"))
            WegaLog.error(.app, "Skan z paska menu — mas outdated: \(error.localizedDescription)")
        }

        var npm: [NpmGlobalOutdated] = []
        do { npm = try await npmService.outdated(); reports.npm = ScanSourceReport(outcome: .succeeded) }
        catch NpmServiceError.npmNotFound { reports.npm = ScanSourceReport(outcome: .notInstalled) }
        catch {
            failed += 1
            reports.npm = ScanSourceReport(outcome: .failed("npm"))
            WegaLog.error(.network, "Skan z paska menu — npm outdated: \(error.localizedDescription)")
        }

        let items = UpdatePlanner.applyPolicies(
            UpdatePlanner.outdatedItems(brew: brew, mas: mas, npm: npm),
            policies: policies
        )

        let brewOutdatedCasks = Set(brew?.casks.map(\.name) ?? [])
        let manual = await scanner.scanReport(brewOutdatedCasks: brewOutdatedCasks)
        failed += manual.failedChecks
        reports.manual = manual.sourceReport
        let visibleManual = UpdatePlanner.applyPolicies(manual.apps, policies: policies)

        return MenuBarScanResult(
            brew: brew,
            mas: mas,
            npm: npm,
            manualApps: manual.apps,
            failedChecks: failed,
            scannedAt: Date(),
            total: items.count + visibleManual.count,
            installationChecks: InstallationCheck.resolvingManagers(manual.installations, reports: reports, brew: brew),
            sources: reports
        )
    }
}
