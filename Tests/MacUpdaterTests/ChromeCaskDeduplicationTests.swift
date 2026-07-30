import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Chrome cask deduplication")
struct ChromeCaskDeduplicationTests {
    @Test("Chrome bundle identity matches the installed Homebrew cask")
    func matchesChromeBundleIdentifierToGoogleChromeCask() throws {
        let applicationsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationsDirectory) }

        let contentsDirectory = applicationsDirectory
            .appendingPathComponent("Google Chrome.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsDirectory,
            withIntermediateDirectories: true
        )
        let infoPlist: [String: Any] = [
            "CFBundleName": "Chrome",
            "CFBundleDisplayName": "Google Chrome",
            "CFBundleIdentifier": "com.google.Chrome",
            "CFBundleShortVersionString": "150.0.7871.187",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsDirectory.appendingPathComponent("Info.plist"))

        let applications = try ApplicationScanner().scanApplications(
            in: applicationsDirectory,
            installedCasks: ["google-chrome"],
            availableCasks: [BrewCask(token: "google-chrome", name: ["Google Chrome"])]
        )

        let chrome = try #require(applications.first)
        #expect(chrome.caskToken == "google-chrome")
        #expect(chrome.isManagedByBrew)
        #expect(chrome.caskMatchProvenance == .bundleIdentifier)
    }
}
