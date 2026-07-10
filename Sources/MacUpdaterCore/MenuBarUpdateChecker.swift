import Foundation

/// A count-only view of a menu-bar check. Kept for callers (and any future ones)
/// that only need the badge numbers; ``MenuBarScanResult/countResult`` produces it.
public struct UpdateCountResult: Equatable, Sendable {
    public var total: Int
    public var failedChecks: Int

    public init(total: Int, failedChecks: Int) {
        self.total = total
        self.failedChecks = failedChecks
    }
}

/// The **full** result of a menu-bar background check: the raw per-source outdated
/// lists (`brew`/`mas`/`npm`) and the manual-scan result (`manualApps` + `failedChecks`),
/// plus the policy-filtered badge `total` and a `scannedAt` timestamp.
///
/// The background check already builds all of these lists to arrive at the count, so
/// carrying them out (instead of discarding them) lets the app window render the result
/// immediately rather than re-scanning from zero. `total` and `failedChecks` are stored
/// so existing count-only callers (`MenuBarAgent`) keep working unchanged, and
/// ``countResult`` hands back the legacy ``UpdateCountResult`` view.
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

    public init(
        brew: BrewOutdated?,
        mas: [MasOutdatedApp],
        npm: [NpmGlobalOutdated],
        manualApps: [ManualOutdatedApp],
        failedChecks: Int,
        scannedAt: Date,
        total: Int
    ) {
        self.brew = brew
        self.mas = mas
        self.npm = npm
        self.manualApps = manualApps
        self.failedChecks = failedChecks
        self.scannedAt = scannedAt
        self.total = total
    }

    /// Count-only projection for callers that only need the badge numbers.
    public var countResult: UpdateCountResult {
        UpdateCountResult(total: total, failedChecks: failedChecks)
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

    /// Note on `scanner`: it no longer inherits the injected `brewService`, because that
    /// parameter is now a protocol and `ManualUpdateScanner` wants the concrete type. In
    /// production both end up with an identically-configured `BrewService` (its dependencies
    /// are all defaulted `let`s), but a test that fakes `brewService` must fake `scanner`
    /// too — they are two seams now, not one.
    public init(
        brewService: BrewOutdatedProviding = BrewService(),
        masService: MasOutdatedProviding = MasService(),
        npmService: NpmOutdatedProviding = NpmGlobalService(),
        scanner: ManualScanning = ManualUpdateScanner()
    ) {
        self.brewService = brewService
        self.masService = masService
        self.npmService = npmService
        self.scanner = scanner
    }

    public func availableUpdateCount(policies: [String: UpdatePolicy] = [:]) async -> MenuBarScanResult {
        var failed = 0

        // F4 — brew missing is "not applicable", exactly as for mas and npm below. Counting
        // it as a failure made the background badge permanently red on machines without it.
        var brew: BrewOutdated?
        do { brew = try await brewService.outdatedGreedy() }
        catch BrewServiceError.brewNotFound { /* Homebrew not installed — nothing to report, not a failure */ }
        catch { failed += 1 }

        var mas: [MasOutdatedApp] = []
        do { mas = try await masService.outdated() }
        catch MasServiceError.masNotFound { /* mas not installed — no App Store updates to report, not a failure */ }
        catch { failed += 1 }

        var npm: [NpmGlobalOutdated] = []
        do { npm = try await npmService.outdated() }
        catch NpmServiceError.npmNotFound { /* npm not installed — no global packages to report, not a failure */ }
        catch { failed += 1 }

        let items = UpdatePlanner.applyPolicies(
            UpdatePlanner.outdatedItems(brew: brew, mas: mas, npm: npm),
            policies: policies
        )

        let brewOutdatedCasks = Set(brew?.casks.map(\.name) ?? [])
        let manual = await scanner.scan(brewOutdatedCasks: brewOutdatedCasks)
        failed += manual.failedChecks
        let visibleManual = UpdatePlanner.applyPolicies(manual.apps, policies: policies)

        return MenuBarScanResult(
            brew: brew,
            mas: mas,
            npm: npm,
            manualApps: manual.apps,
            failedChecks: failed,
            scannedAt: Date(),
            total: items.count + visibleManual.count
        )
    }
}
