import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Thunderbird cask evidence retains Mozilla version semantics")
struct ThunderbirdCaskVersionTests {
    @Test func betaSequenceIsNotErasedByTheGenericCaskComparator() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try betaInstallation(at: directory, version: "146.0b9")
        let check = try #require(ManualUpdateScanner.caskVersionCheck(app: app, brewTrackedVersion: nil,
                                                                    latestCaskVersions: ["thunderbird@beta": "146.0b10"]))
        guard case .outdated(let item) = await check().result else {
            Issue.record("The beta cask must not report Beta 9 current when Beta 10 exists"); return
        }
        #expect(item.availableVersion == "146.0b10")
    }

    @Test func unnumberedBetaCannotBorrowCaskFreshness() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try betaInstallation(at: directory, version: "146.0")
        #expect(ManualUpdateScanner.caskVersionCheck(app: app, brewTrackedVersion: nil,
                                                   latestCaskVersions: ["thunderbird@beta": "146.0b10"]) == nil)
    }

    private func betaInstallation(at path: URL, version: String) throws -> ApplicationInfo {
        let resources = path.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "[App]\nName=Thunderbird\nRemotingName=thunderbird-beta\nVersion=\(version)\n"
            .write(to: resources.appendingPathComponent("application.ini"), atomically: true, encoding: .utf8)
        return ApplicationInfo(path: path, name: "Thunderbird Beta", bundleIdentifier: "org.mozilla.thunderbirdbeta",
                               version: version, installDate: nil, updateDate: nil,
                               isManagedByBrew: false, caskToken: "thunderbird@beta")
    }
}
