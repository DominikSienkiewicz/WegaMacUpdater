import Foundation

public struct UpdateCountResult: Equatable, Sendable {
    public var total: Int
    public var failedChecks: Int

    public init(total: Int, failedChecks: Int) {
        self.total = total
        self.failedChecks = failedChecks
    }
}

/// A **read-only** count of available updates for the menu-bar badge and notifications.
/// Unlike the main Update screen it never mutates the system — no `brew update`, no
/// stale-cask cleanup — so it's safe to run silently on a timer.
public struct MenuBarUpdateChecker: Sendable {
    private let brewService: BrewService
    private let masService: MasService
    private let npmService: NpmGlobalService
    private let scanner: ManualUpdateScanner

    public init(
        brewService: BrewService = BrewService(),
        masService: MasService = MasService(),
        npmService: NpmGlobalService = NpmGlobalService(),
        scanner: ManualUpdateScanner? = nil
    ) {
        self.brewService = brewService
        self.masService = masService
        self.npmService = npmService
        self.scanner = scanner ?? ManualUpdateScanner(brewService: brewService)
    }

    public func availableUpdateCount(policies: [String: UpdatePolicy] = [:]) async -> UpdateCountResult {
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

        return UpdateCountResult(total: items.count + visibleManual.count, failedChecks: failed)
    }
}
