import XCTest
@testable import MacUpdaterCore

/// M3(b) — "check for updates" used to quietly run `brew uninstall --force` on every stale
/// cask it found. Checking must not mutate the system, so the uninstall moved behind a
/// confirmation card. That deferral would resurrect the phantom-outdated bug the silent
/// cleanup was papering over: a cask whose app is gone still reports as outdated, and the
/// counter would lie. So the same scan that surfaces the card also filters the list.
final class StaleCaskExclusionTests: XCTestCase {
    private func outdated(formulae: [String], casks: [String]) -> BrewOutdated {
        BrewOutdated(
            formulae: formulae.map { BrewOutdatedItem(name: $0, installedVersions: ["1"], currentVersion: "2") },
            casks: casks.map { BrewOutdatedItem(name: $0, installedVersions: ["1"], currentVersion: "2") }
        )
    }

    func testStaleCasksAreDroppedFromTheOutdatedList() throws {
        let filtered = try XCTUnwrap(UpdatePlanner.excludingStaleCasks(
            outdated(formulae: [], casks: ["docker", "ghost-cask"]),
            staleTokens: ["ghost-cask"]
        ))
        XCTAssertEqual(filtered.casks.map(\.name), ["docker"])
    }

    func testFormulaeAreNeverAffectedByStaleCaskTokens() throws {
        let filtered = try XCTUnwrap(UpdatePlanner.excludingStaleCasks(
            outdated(formulae: ["ghost-cask"], casks: []),
            staleTokens: ["ghost-cask"]
        ))
        XCTAssertEqual(filtered.formulae.map(\.name), ["ghost-cask"])
    }

    func testNothingStaleLeavesTheListUntouched() {
        let original = outdated(formulae: ["git"], casks: ["docker"])
        XCTAssertEqual(UpdatePlanner.excludingStaleCasks(original, staleTokens: []), original)
    }

    func testAbsentBrewResultStaysAbsent() {
        XCTAssertNil(UpdatePlanner.excludingStaleCasks(nil, staleTokens: ["ghost-cask"]))
    }

    /// The counter must reflect what the user can act on, so an all-stale list is empty.
    func testEveryCaskStaleLeavesNoCasks() throws {
        let filtered = try XCTUnwrap(UpdatePlanner.excludingStaleCasks(
            outdated(formulae: [], casks: ["ghost-a", "ghost-b"]),
            staleTokens: ["ghost-a", "ghost-b"]
        ))
        XCTAssertTrue(filtered.casks.isEmpty)
    }
}
