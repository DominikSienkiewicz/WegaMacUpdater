import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Thunderbird cask adoption preserves the installed channel")
struct ThunderbirdCaskChannelTests {
    @Test(arguments: ["thunderbird-esr", "thunderbird-beta", "thunderbird-nightly", "unknown", ""])
    func releaseCaskCannotReplaceAnotherOrUnknownChannel(remotingName: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try installation(in: directory, remotingName: remotingName, token: "thunderbird")
        #expect(ManualUpdateScanner.caskVersionCheck(app: app, brewTrackedVersion: nil,
                                                   latestCaskVersions: ["thunderbird": "145.0.1"]) == nil)
    }

    @Test(arguments: [
        ["thunderbird", "thunderbird@esr"],
        ["thunderbird", "thunderbird@beta"],
        ["thunderbird-esr", "thunderbird@beta"],
        ["thunderbird-beta", "thunderbird@esr"]
    ])
    func caskChannelMismatchCannotBecomeAnAdoptionOffer(pair: [String]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try installation(in: directory, remotingName: pair[0], token: pair[1])
        #expect(ManualUpdateScanner.caskVersionCheck(app: app, brewTrackedVersion: nil,
                                                   latestCaskVersions: [pair[1]: "145.0.1"]) == nil)
    }

    @Test(arguments: [
        ["thunderbird", "thunderbird"],
        ["thunderbird-esr", "thunderbird@esr"],
        ["thunderbird-beta", "thunderbird@beta"]
    ])
    func matchingCaskChannelRemainsAvailable(pair: [String]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try installation(in: directory, remotingName: pair[0], token: pair[1])
        #expect(ManualUpdateScanner.caskVersionCheck(app: app, brewTrackedVersion: nil,
                                                   latestCaskVersions: [pair[1]: "145.0.1"]) != nil)
    }

    private func installation(in directory: URL, remotingName: String, token: String) throws -> ApplicationInfo {
        let path = directory.appendingPathComponent("Thunderbird.app")
        let resources = path.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if !remotingName.isEmpty {
            try "[App]\nName=Thunderbird\nRemotingName=\(remotingName)\nVersion=140.4.0\n"
                .write(to: resources.appendingPathComponent("application.ini"), atomically: true, encoding: .utf8)
        }
        return ApplicationInfo(path: path, name: "Thunderbird", bundleIdentifier: "org.mozilla.thunderbird",
                               version: remotingName == "thunderbird-beta" ? "140.4.0b1" : "140.4.0", installDate: nil, updateDate: nil,
                               isManagedByBrew: false, caskToken: token)
    }
}
