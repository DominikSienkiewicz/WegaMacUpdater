import XCTest
@testable import MacUpdaterCore

final class BrewInfoParserTests: XCTestCase {
    func testParsesAppArtifactsFromCaskInfoFixture() throws {
        let data = try fixtureData(named: "brew-info-casks", extension: "json")

        let result = try BrewInfoParser().parseCaskInstallations(data)

        XCTAssertEqual(result[0], BrewCaskInstallationInfo(token: "visual-studio-code", appArtifacts: ["Visual Studio Code.app"]))
        XCTAssertEqual(result[1], BrewCaskInstallationInfo(token: "font-fira-code", appArtifacts: []))
        XCTAssertEqual(result[2], BrewCaskInstallationInfo(token: "postman", appArtifacts: ["Postman.app"]))
    }
}
