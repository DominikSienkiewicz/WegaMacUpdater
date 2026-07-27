import XCTest
@testable import MacUpdaterCore

final class NpmOutdatedParserTests: XCTestCase {
    func testParsesOutdatedGlobalsSkippingNpmAndCorepack() throws {
        let json = #"""
        {
          "@openai/codex": { "current": "0.125.0", "wanted": "0.130.0", "latest": "0.130.0", "location": "/x" },
          "corepack":      { "current": "0.34.6",  "wanted": "0.35.0",  "latest": "0.35.0" },
          "npm":           { "current": "11.13.0", "wanted": "11.14.0", "latest": "11.14.0" },
          "pnpm":          { "current": "9.15.9",  "wanted": "10.0.0",  "latest": "10.0.0" }
        }
        """#

        let result = try NpmOutdatedParser().parse(json)

        // npm and corepack are filtered out — they are not user-actionable upgrades here.
        XCTAssertEqual(result.map(\.name), ["@openai/codex", "pnpm"])
        XCTAssertEqual(result.first?.installedVersion, "0.125.0")
        XCTAssertEqual(result.first?.latestVersion, "0.130.0")
    }

    func testReturnsEmptyForNpmNothingOutdatedPayload() throws {
        XCTAssertTrue(try NpmOutdatedParser().parse("{}").isEmpty)
    }

    func testSkipsEntriesMissingCurrentOrLatestOrMarkedMissing() throws {
        let json = #"""
        {
          "no-current": { "wanted": "2.0.0", "latest": "2.0.0" },
          "no-latest":  { "current": "1.0.0", "wanted": "2.0.0" },
          "not-installed": { "current": "MISSING", "latest": "2.0.0" },
          "ok":         { "current": "1.0.0", "wanted": "2.0.0", "latest": "2.0.0" }
        }
        """#

        XCTAssertEqual(try NpmOutdatedParser().parse(json).map(\.name), ["ok"])
    }

    func testDropsEntriesThatAreNotAnUpgrade() throws {
        // REL-11: a prerelease ranks below its release and an equal version is not an
        // upgrade, so neither should be reported even if npm listed it.
        let json = #"""
        {
          "equal":      { "current": "1.0.0", "latest": "1.0.0" },
          "prerelease": { "current": "2.0.0", "latest": "2.0.0-beta.1" },
          "upgrade":    { "current": "1.0.0", "latest": "1.2.0" }
        }
        """#

        XCTAssertEqual(try NpmOutdatedParser().parse(json).map(\.name), ["upgrade"])
    }
}
