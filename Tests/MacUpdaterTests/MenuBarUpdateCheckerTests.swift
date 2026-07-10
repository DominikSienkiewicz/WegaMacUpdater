import XCTest
@testable import MacUpdaterCore

// MARK: - Fakes

private struct FakeBrew: BrewOutdatedProviding {
    var result: Result<BrewOutdated, Error>
    func outdatedGreedy() async throws -> BrewOutdated { try result.get() }
}

private struct FakeMas: MasOutdatedProviding {
    var result: Result<[MasOutdatedApp], Error>
    func outdated() async throws -> [MasOutdatedApp] { try result.get() }
}

private struct FakeNpm: NpmOutdatedProviding {
    var result: Result<[NpmGlobalOutdated], Error>
    func outdated() async throws -> [NpmGlobalOutdated] { try result.get() }
}

private struct FakeScanner: ManualScanning {
    var apps: [ManualOutdatedApp] = []
    var failedChecks: Int = 0
    func scan(brewOutdatedCasks: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        (apps, failedChecks)
    }
}

private func manualApp(_ name: String, available: String = "2.0") -> ManualOutdatedApp {
    ManualOutdatedApp(
        name: name,
        path: URL(fileURLWithPath: "/Applications/\(name).app"),
        installedVersion: "1.0",
        availableVersion: available,
        source: .sparkle
    )
}

final class MenuBarUpdateCheckerTests: XCTestCase {
    private func checker(
        brew: Result<BrewOutdated, Error> = .success(BrewOutdated(formulae: [], casks: [])),
        mas: Result<[MasOutdatedApp], Error> = .success([]),
        npm: Result<[NpmGlobalOutdated], Error> = .success([]),
        scanner: FakeScanner = FakeScanner()
    ) -> MenuBarUpdateChecker {
        MenuBarUpdateChecker(
            brewService: FakeBrew(result: brew),
            masService: FakeMas(result: mas),
            npmService: FakeNpm(result: npm),
            scanner: scanner
        )
    }

    /// The result must carry the raw per-source lists and the manual apps, not just a count.
    func testResultCarriesLists() async {
        let brew = BrewOutdated(
            formulae: [BrewOutdatedItem(name: "wget", installedVersions: ["1.0"], currentVersion: "1.1")],
            casks: [BrewOutdatedItem(name: "iterm2", installedVersions: ["3.4"], currentVersion: "3.5")]
        )
        let mas = [MasOutdatedApp(appStoreID: "497799835", name: "Xcode", installedVersion: "15", currentVersion: "16")]
        let npm = [NpmGlobalOutdated(name: "typescript", installedVersion: "5.0", latestVersion: "5.4")]
        let manual = [manualApp("Transmission")]

        let result = await checker(
            brew: .success(brew),
            mas: .success(mas),
            npm: .success(npm),
            scanner: FakeScanner(apps: manual)
        ).availableUpdateCount()

        XCTAssertEqual(result.brew, brew)
        XCTAssertEqual(result.mas, mas)
        XCTAssertEqual(result.npm, npm)
        XCTAssertEqual(result.manualApps, manual)
    }

    /// The badge total must equal the package items plus the visible manual updates.
    func testTotalEqualsItemsPlusVisibleManual() async {
        let brew = BrewOutdated(
            formulae: [BrewOutdatedItem(name: "wget", installedVersions: ["1.0"], currentVersion: "1.1")],
            casks: [BrewOutdatedItem(name: "iterm2", installedVersions: ["3.4"], currentVersion: "3.5")]
        )
        let mas = [MasOutdatedApp(appStoreID: "497799835", name: "Xcode", installedVersion: "15", currentVersion: "16")]
        let npm = [NpmGlobalOutdated(name: "typescript", installedVersion: "5.0", latestVersion: "5.4")]
        let manual = [manualApp("Transmission"), manualApp("VLC")]

        let result = await checker(
            brew: .success(brew),
            mas: .success(mas),
            npm: .success(npm),
            scanner: FakeScanner(apps: manual)
        ).availableUpdateCount()

        // 2 brew (formula + cask) + 1 mas + 1 npm = 4 package items, + 2 manual = 6.
        XCTAssertEqual(result.total, 6)

        // And it agrees with recomputing from the carried lists.
        let items = UpdatePlanner.outdatedItems(brew: result.brew, mas: result.mas, npm: result.npm)
        XCTAssertEqual(result.total, items.count + result.manualApps.count)
    }

    /// An ignore policy must be honoured in the badge total even though the raw lists stay full.
    func testPoliciesAreHonouredInTotal() async {
        let brew = BrewOutdated(
            formulae: [BrewOutdatedItem(name: "wget", installedVersions: ["1.0"], currentVersion: "1.1")],
            casks: []
        )
        let manual = [manualApp("Transmission")]

        let result = await checker(
            brew: .success(brew),
            scanner: FakeScanner(apps: manual)
        ).availableUpdateCount(policies: [
            "f:wget": .ignored,
            "manual:transmission": .ignored
        ])

        // Both suppressed → badge shows 0, but the raw lists are still carried.
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(result.brew?.formulae.count, 1)
        XCTAssertEqual(result.manualApps.count, 1)
    }

    /// brew not being installed (`brewNotFound`) is *not installed*, not a failed check.
    func testMissingBrewDoesNotBumpFailedChecks() async {
        let result = await checker(
            brew: .failure(BrewServiceError.brewNotFound)
        ).availableUpdateCount()

        XCTAssertEqual(result.failedChecks, 0)
        XCTAssertNil(result.brew)
    }

    /// A genuine brew error (not "not found") *does* count as a failed check.
    func testBrewErrorBumpsFailedChecks() async {
        struct Boom: Error {}
        let result = await checker(
            brew: .failure(Boom())
        ).availableUpdateCount()

        XCTAssertEqual(result.failedChecks, 1)
    }
}
