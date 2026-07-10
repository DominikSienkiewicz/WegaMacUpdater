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

    // MARK: - Artifact profiles + homepage (shared prerequisite for F1/F2/F3)

    func testParsesHomepagePerCask() throws {
        let data = try fixtureData(named: "brew-info-cask-artifacts", extension: "json")

        let profiles = try BrewInfoParser().parseCaskArtifactProfiles(data)

        XCTAssertEqual(profiles[0].token, "visual-studio-code")
        XCTAssertEqual(profiles[0].homepage, "https://code.visualstudio.com/")
        XCTAssertEqual(profiles[1].homepage, "https://www.docker.com/products/docker-desktop/")
        XCTAssertNil(profiles[3].homepage, "font cask has no homepage → nil, not empty string")
    }

    func testParsesArtifactKindsPreservingAppTargets() throws {
        let data = try fixtureData(named: "brew-info-cask-artifacts", extension: "json")

        let profiles = try BrewInfoParser().parseCaskArtifactProfiles(data)

        XCTAssertEqual(profiles[0].artifactKinds, [.app, .binary, .zap])
        XCTAssertEqual(profiles[0].appArtifacts, ["Visual Studio Code.app"])
        XCTAssertEqual(profiles[3].artifactKinds, [.other("font")], "unknown artifact kinds are preserved verbatim")
    }

    func testDetectsPresenceOfPrivilegedArtifactHooks() throws {
        let data = try fixtureData(named: "brew-info-cask-artifacts", extension: "json")

        let profiles = try BrewInfoParser().parseCaskArtifactProfiles(data)

        // docker-desktop ships a pkg; little-snitch ships preflight + installer.
        XCTAssertTrue(profiles[1].contains(.pkg))
        XCTAssertTrue(profiles[2].contains(.preflight))
        XCTAssertTrue(profiles[2].contains(.installer))
        // visual-studio-code ships none of them.
        XCTAssertTrue(profiles[0].artifactKinds.isDisjoint(with: [.pkg, .installer, .preflight]))
    }

    func testInstallationInfoIsDerivedFromArtifactProfiles() throws {
        // Backward-compatibility: appArtifacts still resolves to app targets only.
        let data = try fixtureData(named: "brew-info-cask-artifacts", extension: "json")

        let result = try BrewInfoParser().parseCaskInstallations(data)

        XCTAssertEqual(result[0], BrewCaskInstallationInfo(token: "visual-studio-code", appArtifacts: ["Visual Studio Code.app"]))
        XCTAssertEqual(result[1], BrewCaskInstallationInfo(token: "docker-desktop", appArtifacts: []))
        XCTAssertEqual(result[3], BrewCaskInstallationInfo(token: "font-fira-code", appArtifacts: []))
    }
}
