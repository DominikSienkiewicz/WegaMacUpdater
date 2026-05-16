import XCTest
@testable import MacUpdaterCore

final class NpmListParserTests: XCTestCase {
    func testParsesGlobalPackagesSkippingNpmAndCorepack() throws {
        let json = #"""
        {
          "name": "lib",
          "dependencies": {
            "@openai/codex": { "version": "0.125.0", "overridden": false },
            "corepack":      { "version": "0.34.6",  "overridden": false },
            "npm":           { "version": "11.13.0", "overridden": false },
            "pnpm":          { "version": "9.15.9",  "overridden": false },
            "tsx":           { "version": "4.21.0",  "overridden": false }
          }
        }
        """#

        let result = try NpmListParser().parse(json)

        // npm and corepack are intentionally filtered out — they are not user-actionable upgrades here.
        XCTAssertEqual(result.map(\.name), ["@openai/codex", "pnpm", "tsx"])
        XCTAssertEqual(result.first?.installedVersion, "0.125.0")
    }

    func testReturnsEmptyForMissingDependencies() throws {
        let result = try NpmListParser().parse(#"{"name":"lib"}"#)
        XCTAssertTrue(result.isEmpty)
    }

    func testSkipsEntriesWithoutVersion() throws {
        let json = #"""
        {"dependencies":{"broken":{"overridden":false},"ok":{"version":"1.0.0"}}}
        """#
        let result = try NpmListParser().parse(json)
        XCTAssertEqual(result.map(\.name), ["ok"])
    }
}
