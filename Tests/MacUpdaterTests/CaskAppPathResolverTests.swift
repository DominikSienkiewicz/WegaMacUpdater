import XCTest
@testable import MacUpdaterCore

/// REL-03 — the resolution the snapshot → canary → rollback chain now depends on, tested
/// against an injected filesystem so it never depends on what is installed on the machine
/// running the suite.
final class CaskAppPathResolverTests: XCTestCase {

    private let systemApps = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private let userApps = URL(fileURLWithPath: "/Users/tester/Applications", isDirectory: true)

    private func resolver(existing: Set<String>) -> CaskAppPathResolver {
        CaskAppPathResolver(
            applicationsDirectory: systemApps,
            userApplicationsDirectory: userApps,
            fileExists: { existing.contains($0.path) }
        )
    }

    func testResolvesASystemWideInstall() {
        let paths = resolver(existing: ["/Applications/iTerm.app"])
            .appPaths(from: [BrewCaskInstallationInfo(token: "iterm2", appArtifacts: ["iTerm.app"])])

        XCTAssertEqual(paths, ["iterm2": systemApps.appendingPathComponent("iTerm.app")])
    }

    func testFallsBackToThePerUserApplicationsFolder() {
        let paths = resolver(existing: ["/Users/tester/Applications/iTerm.app"])
            .appPaths(from: [BrewCaskInstallationInfo(token: "iterm2", appArtifacts: ["iTerm.app"])])

        XCTAssertEqual(paths, ["iterm2": userApps.appendingPathComponent("iTerm.app")])
    }

    func testPrefersTheSystemWideInstallWhenBothExist() {
        let paths = resolver(existing: ["/Applications/iTerm.app", "/Users/tester/Applications/iTerm.app"])
            .appPaths(from: [BrewCaskInstallationInfo(token: "iterm2", appArtifacts: ["iTerm.app"])])

        XCTAssertEqual(paths["iterm2"], systemApps.appendingPathComponent("iTerm.app"))
    }

    /// A cask whose bundle is not on disk must be *absent*, not mapped to a path that does
    /// not exist: absence is what `CaskRollbackGuard` reads as "this one cannot be protected".
    func testACaskWithNoBundleOnDiskIsOmitted() {
        let paths = resolver(existing: [])
            .appPaths(from: [BrewCaskInstallationInfo(token: "iterm2", appArtifacts: ["iTerm.app"])])

        XCTAssertTrue(paths.isEmpty)
    }

    func testACaskThatInstallsNoAppIsOmitted() {
        let paths = resolver(existing: ["/Applications/iTerm.app"])
            .appPaths(from: [BrewCaskInstallationInfo(token: "font-fira-code", appArtifacts: [])])

        XCTAssertTrue(paths.isEmpty)
    }

    /// The first artifact that exists wins — a cask may declare several, only one of which
    /// this machine actually installed.
    func testTakesTheFirstArtifactThatExists() {
        let paths = resolver(existing: ["/Applications/Second.app"])
            .appPaths(from: [BrewCaskInstallationInfo(token: "multi", appArtifacts: ["First.app", "Second.app"])])

        XCTAssertEqual(paths["multi"], systemApps.appendingPathComponent("Second.app"))
    }

    /// Drifted casks are dropped from the outdated list, so they must not turn up in the
    /// icon map the scan builds either.
    func testExcludedTokensAreSkipped() {
        let paths = resolver(existing: ["/Applications/Google Chrome.app", "/Applications/iTerm.app"])
            .appPaths(
                from: [
                    BrewCaskInstallationInfo(token: "google-chrome", appArtifacts: ["Google Chrome.app"]),
                    BrewCaskInstallationInfo(token: "iterm2", appArtifacts: ["iTerm.app"])
                ],
                excluding: ["google-chrome"]
            )

        XCTAssertEqual(Array(paths.keys), ["iterm2"])
    }

    func testNoInstallationInfoResolvesToNothing() {
        XCTAssertTrue(resolver(existing: ["/Applications/iTerm.app"]).appPaths(from: []).isEmpty)
    }
}
