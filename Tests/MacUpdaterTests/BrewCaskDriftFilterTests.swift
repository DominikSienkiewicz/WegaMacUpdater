import XCTest
@testable import MacUpdaterCore

final class BrewCaskDriftFilterTests: XCTestCase {
    private let appsDir = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private let userAppsDir = URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)

    private func makeFilter(_ versions: [String: String]) -> BrewCaskDriftFilter {
        BrewCaskDriftFilter(
            applicationsDir: appsDir,
            userApplicationsDir: userAppsDir,
            readBundleVersion: { versions[$0.path] }
        )
    }

    /// Reproduces the Chrome bug: brew records installed=148.0.7778.179 but the
    /// on-disk app reports CFBundleShortVersionString=148.0.7778.216 because
    /// Chrome self-updated outside of Homebrew. The cask is effectively
    /// up-to-date and must be hidden from the outdated list.
    func testDropsCaskWhenAppVersionMatchesCurrentVersion() {
        let filter = makeFilter([
            "/Applications/Google Chrome.app": "148.0.7778.216"
        ])
        let drifted = filter.driftedTokens(
            outdated: [
                BrewOutdatedItem(
                    name: "google-chrome",
                    installedVersions: ["148.0.7778.179"],
                    currentVersion: "148.0.7778.216"
                )
            ],
            installationInfo: [
                BrewCaskInstallationInfo(token: "google-chrome", appArtifacts: ["Google Chrome.app"])
            ]
        )
        XCTAssertEqual(drifted, ["google-chrome"])
    }

    func testDropsCaskWhenAppVersionExceedsCurrentVersion() {
        let filter = makeFilter(["/Applications/Foo.app": "2.1.0"])
        let drifted = filter.driftedTokens(
            outdated: [BrewOutdatedItem(name: "foo", installedVersions: ["2.0.0"], currentVersion: "2.0.5")],
            installationInfo: [BrewCaskInstallationInfo(token: "foo", appArtifacts: ["Foo.app"])]
        )
        XCTAssertEqual(drifted, ["foo"])
    }

    func testKeepsCaskWhenAppVersionIsOlderThanCurrent() {
        let filter = makeFilter(["/Applications/Foo.app": "1.0.0"])
        let drifted = filter.driftedTokens(
            outdated: [BrewOutdatedItem(name: "foo", installedVersions: ["1.0.0"], currentVersion: "2.0.0")],
            installationInfo: [BrewCaskInstallationInfo(token: "foo", appArtifacts: ["Foo.app"])]
        )
        XCTAssertTrue(drifted.isEmpty)
    }

    func testKeepsCaskWhenBundleVersionIsUnreadable() {
        let filter = makeFilter([:])
        let drifted = filter.driftedTokens(
            outdated: [BrewOutdatedItem(name: "foo", installedVersions: ["1.0.0"], currentVersion: "2.0.0")],
            installationInfo: [BrewCaskInstallationInfo(token: "foo", appArtifacts: ["Foo.app"])]
        )
        XCTAssertTrue(drifted.isEmpty)
    }

    func testFallsBackToUserApplicationsDirectory() {
        let filter = makeFilter([
            "/Users/test/Applications/Foo.app": "2.0.0"
        ])
        let drifted = filter.driftedTokens(
            outdated: [BrewOutdatedItem(name: "foo", installedVersions: ["1.0.0"], currentVersion: "2.0.0")],
            installationInfo: [BrewCaskInstallationInfo(token: "foo", appArtifacts: ["Foo.app"])]
        )
        XCTAssertEqual(drifted, ["foo"])
    }

    func testKeepsCaskWithoutInstallationInfo() {
        let filter = makeFilter(["/Applications/Foo.app": "2.0.0"])
        let drifted = filter.driftedTokens(
            outdated: [BrewOutdatedItem(name: "foo", installedVersions: ["1.0.0"], currentVersion: "2.0.0")],
            installationInfo: []
        )
        XCTAssertTrue(drifted.isEmpty)
    }
}
