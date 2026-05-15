import XCTest
@testable import MacUpdaterCore

final class StaleCaskDetectorTests: XCTestCase {
    func testReturnsCaskOnlyWhenAllAppArtifactsAreMissing() {
        let applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplicationsDirectory = URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
        let existingPath = applicationsDirectory.appendingPathComponent("Visual Studio Code.app")

        let detector = StaleCaskDetector(
            applicationsDirectory: applicationsDirectory,
            userApplicationsDirectory: userApplicationsDirectory,
            fileExists: { $0 == existingPath }
        )

        let stale = detector.staleCasks(from: [
            BrewCaskInstallationInfo(token: "visual-studio-code", appArtifacts: ["Visual Studio Code.app"]),
            BrewCaskInstallationInfo(token: "postman", appArtifacts: ["Postman.app"]),
            BrewCaskInstallationInfo(token: "font-fira-code", appArtifacts: [])
        ])

        XCTAssertEqual(stale, ["postman"])
    }
}
