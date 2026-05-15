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

        XCTAssertEqual(match, .candidate(token: "cleanmymac"))
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

        XCTAssertEqual(match, .managed(token: "visual-studio-code"))
    }

    func testMarksInstalledTokenAsManagedWhenOnlyNormalizedNamesMatch() {
        let matcher = CaskMatcher()

        let match = matcher.match(
            applicationName: "Visual Studio Code",
            installedCasks: ["visual-studio-code"],
            availableCasks: []
        )

        XCTAssertEqual(match, .managed(token: "visual-studio-code"))
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

        XCTAssertEqual(match, .candidate(token: "parallels"))
    }
}
