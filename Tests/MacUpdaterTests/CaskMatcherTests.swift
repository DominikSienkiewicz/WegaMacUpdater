import XCTest
@testable import MacUpdaterCore

final class CaskMatcherTests: XCTestCase {
    func testUsesCustomMappingsBeforeDatabaseMatch() {
        let matcher = CaskMatcher(customMappings: ["CleanMyMac_5": "cleanmymac"])

        let match = matcher.match(
            applicationName: "CleanMyMac_5",
            installedCasks: [],
            availableCasks: []
        )

        XCTAssertEqual(match, .candidate(token: "cleanmymac", provenance: .curatedMapping))
    }

    func testMarksInstalledTokenAsManaged() {
        let matcher = CaskMatcher()

        let match = matcher.match(
            applicationName: "Visual Studio Code",
            installedCasks: ["visual-studio-code"],
            availableCasks: [
                BrewCask(token: "visual-studio-code", name: ["Visual Studio Code"])
            ]
        )

        XCTAssertEqual(match, .managed(token: "visual-studio-code", provenance: .installedToken))
    }

    func testMarksInstalledTokenAsManagedWhenOnlyNormalizedNamesMatch() {
        let matcher = CaskMatcher()

        let match = matcher.match(
            applicationName: "Visual Studio Code",
            installedCasks: ["visual-studio-code"],
            availableCasks: []
        )

        XCTAssertEqual(match, .managed(token: "visual-studio-code", provenance: .installedToken))
    }

    func testMatchesByCaskDisplayName() {
        let matcher = CaskMatcher()

        let match = matcher.match(
            applicationName: "Parallels Desktop",
            installedCasks: [],
            availableCasks: [
                BrewCask(token: "parallels", name: ["Parallels Desktop"])
            ]
        )

        // LT-03 — the token assertion is unchanged, but the provenance shows this case never
        // exercised the display-name path it is named after: the default matcher's curated
        // table maps "Parallels Desktop" → "parallels" and is consulted first. A genuine
        // display-name match is covered in LT03MatchProvenanceTests.
        XCTAssertEqual(match, .candidate(token: "parallels", provenance: .curatedMapping))
    }
}
