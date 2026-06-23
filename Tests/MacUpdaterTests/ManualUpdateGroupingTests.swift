import XCTest
@testable import MacUpdaterCore

/// The Updates window groups manual updates by install origin (the same axis the
/// Inventory window labels), so a Homebrew-cask app is presented as Brew in both
/// windows. These tests pin that grouping.
final class ManualUpdateGroupingTests: XCTestCase {
    private func item(
        name: String,
        origin: AppOrigin,
        source: ManualOutdatedApp.UpdateSource
    ) -> ManualOutdatedApp {
        ManualOutdatedApp(
            name: name,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            installedVersion: "1.0",
            availableVersion: "2.0",
            source: source,
            origin: origin
        )
    }

    // Regression for the reported bug: Docker is a Homebrew cask (origin .brew) whose
    // update is surfaced via the cask-version check (source .cask). It must group with
    // Brew — exactly what the Inventory window labels it — never under "manual".
    func testBrewOriginCaskItemGroupsWithBrewNotManual() {
        let docker = item(name: "Docker", origin: .brew, source: .cask(token: "docker-desktop"))
        let groups = UpdatePlanner.groupManual([docker])
        XCTAssertEqual(groups.brew.map(\.name), ["Docker"])
        XCTAssertTrue(groups.manual.isEmpty, "a brew-managed app must not land in the manual group")
    }

    func testManualOriginItemGroupsAsManual() {
        let sparkleApp = item(name: "Transmit", origin: .manual, source: .sparkle)
        let groups = UpdatePlanner.groupManual([sparkleApp])
        XCTAssertEqual(groups.manual.map(\.name), ["Transmit"])
        XCTAssertTrue(groups.brew.isEmpty)
    }

    // A self-updating app that IS a Homebrew cask (e.g. ChatGPT/Postman, whose update we
    // fetch from the vendor because the cask lags) still groups with Brew, so both
    // windows agree on "Brew" — even though its update action isn't `brew install`.
    func testBrewOriginSelfUpdatingItemGroupsWithBrew() {
        let chatgpt = item(name: "ChatGPT", origin: .brew, source: .chatgpt)
        let groups = UpdatePlanner.groupManual([chatgpt])
        XCTAssertEqual(groups.brew.map(\.name), ["ChatGPT"])
        XCTAssertTrue(groups.manual.isEmpty)
    }

    func testOriginDefaultsToManualWhenUnset() {
        let app = ManualOutdatedApp(
            name: "X",
            path: URL(fileURLWithPath: "/Applications/X.app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle
        )
        XCTAssertEqual(app.origin, .manual)
    }
}
