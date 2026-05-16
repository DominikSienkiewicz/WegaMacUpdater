import XCTest
@testable import MacUpdaterCore

final class NpmBrewDuplicateDetectorTests: XCTestCase {
    func testScopedNpmPackageMatchesUnscopedBrewToken() {
        let dups = NpmBrewDuplicateDetector().detect(
            npmPackages: [NpmGlobalPackage(name: "@openai/codex", installedVersion: "0.125.0")],
            brewTokens: ["codex", "ripgrep"]
        )
        XCTAssertEqual(dups, [NpmBrewDuplicate(npmPackage: "@openai/codex", brewToken: "codex")])
    }

    func testPlainNameMatch() {
        let dups = NpmBrewDuplicateDetector().detect(
            npmPackages: [NpmGlobalPackage(name: "pnpm", installedVersion: "9.0.0")],
            brewTokens: ["pnpm"]
        )
        XCTAssertEqual(dups.map(\.brewToken), ["pnpm"])
    }

    func testNoDuplicatesWhenNamesDiffer() {
        let dups = NpmBrewDuplicateDetector().detect(
            npmPackages: [NpmGlobalPackage(name: "tsx", installedVersion: "4.0.0")],
            brewTokens: ["wget", "git"]
        )
        XCTAssertTrue(dups.isEmpty)
    }
}
