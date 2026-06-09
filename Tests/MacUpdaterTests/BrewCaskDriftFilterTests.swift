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

    /// Reproduces the LM Studio bug: brew records installed=0.4.16,1 and offers
    /// current=0.4.16,2 (a genuine build-metadata bump), while the on-disk app
    /// reports CFBundleShortVersionString=0.4.16+1. The app is genuinely behind —
    /// the only difference is the build segment (+1 vs ,2) — so it must NOT be
    /// treated as metadata drift and must stay on the outdated list.
    func testKeepsCaskWhenOnlyBuildMetadataIsBehind() {
        let filter = makeFilter(["/Applications/LM Studio.app": "0.4.16+1"])
        let drifted = filter.driftedTokens(
            outdated: [BrewOutdatedItem(name: "lm-studio", installedVersions: ["0.4.16,1"], currentVersion: "0.4.16,2")],
            installationInfo: [BrewCaskInstallationInfo(token: "lm-studio", appArtifacts: ["LM Studio.app"])]
        )
        XCTAssertTrue(drifted.isEmpty)
    }

    /// The mirror of the LM Studio case: when the on-disk build segment matches the
    /// cask's, the app really has self-updated and should be hidden as drift.
    func testDropsCaskWhenBuildMetadataMatches() {
        let filter = makeFilter(["/Applications/LM Studio.app": "0.4.16+2"])
        let drifted = filter.driftedTokens(
            outdated: [BrewOutdatedItem(name: "lm-studio", installedVersions: ["0.4.16,1"], currentVersion: "0.4.16,2")],
            installationInfo: [BrewCaskInstallationInfo(token: "lm-studio", appArtifacts: ["LM Studio.app"])]
        )
        XCTAssertEqual(drifted, ["lm-studio"])
    }

    /// Guards the Homebrew comma-encoding case: a bare on-disk version ("5.3.1")
    /// must still be treated as equal to the cask's "5.3.1,50301" (only one side
    /// carries a build segment, so it is encoding noise, not a real difference).
    func testDropsCaskWhenBrewAddsBuildSuffixToBareVersion() {
        let filter = makeFilter(["/Applications/Foo.app": "5.3.1"])
        let drifted = filter.driftedTokens(
            outdated: [BrewOutdatedItem(name: "foo", installedVersions: ["5.3.1,50301"], currentVersion: "5.3.1,50301")],
            installationInfo: [BrewCaskInstallationInfo(token: "foo", appArtifacts: ["Foo.app"])]
        )
        XCTAssertEqual(drifted, ["foo"])
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
