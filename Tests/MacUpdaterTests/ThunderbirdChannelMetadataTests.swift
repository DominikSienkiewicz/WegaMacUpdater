import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Thunderbird metadata remains explicit and unambiguous")
struct ThunderbirdChannelMetadataTests {
    @Test func olderBundleCanDeclareItsChannelInPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(#"pref("app.update.channel", "esr");"#, to: directory,
                  resource: "defaults/pref/channel-prefs.js")
        #expect(ThunderbirdInstallationChannel.read(at: directory) == .esr)
    }

    @Test func conflictingMetadataDoesNotGuessAChannel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("[App]\nRemotingName=thunderbird-esr\n", to: directory, resource: "application.ini")
        try write(#"pref("app.update.channel", "release");"#, to: directory,
                  resource: "defaults/pref/channel-prefs.js")
        #expect(ThunderbirdInstallationChannel.read(at: directory) == nil)
    }

    @Test func commentedPreferenceDoesNotSupplyChannelEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(#"// pref("app.update.channel", "release");"#, to: directory,
                  resource: "defaults/pref/channel-prefs.js")
        #expect(ThunderbirdInstallationChannel.read(at: directory) == nil)
    }

    private func write(_ content: String, to app: URL, resource: String) throws {
        let path = app.appendingPathComponent("Contents/Resources").appendingPathComponent(resource)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: path, atomically: true, encoding: .utf8)
    }
}
