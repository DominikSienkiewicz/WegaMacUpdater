import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Thunderbird recovery rows cannot reintroduce a foreign channel")
struct ThunderbirdCaskRecoveryChannelTests {
    @Test(arguments: ["thunderbird-esr", "thunderbird-beta", "unknown", ""])
    func wrongOrUnknownChannelCannotBecomeADriftOrRollbackRow(remotingName: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Thunderbird.app")
        let resources = path.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if !remotingName.isEmpty {
            try "[App]\nName=Thunderbird\nRemotingName=\(remotingName)\nVersion=140.4.0\n"
                .write(to: resources.appendingPathComponent("application.ini"), atomically: true, encoding: .utf8)
        }
        let app = ApplicationInfo(path: path, name: "Thunderbird", bundleIdentifier: "org.mozilla.thunderbird",
                                  version: "140.4.0", installDate: nil, updateDate: nil,
                                  isManagedByBrew: true, caskToken: "thunderbird")
        #expect(ManualUpdateScanner.caskMetadataDriftRows(installedApps: [app], brewCaskVersions: ["thunderbird": "145.0"],
                                                        alreadyListedTokens: []).isEmpty)
        #expect(ManualUpdateScanner.rolledBackRows(rolledBackTokens: ["thunderbird"], installedApps: [app],
                                                 brewCaskVersions: ["thunderbird": "145.0"], alreadyListedTokens: []).isEmpty)
    }
}
