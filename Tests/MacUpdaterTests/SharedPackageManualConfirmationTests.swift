import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("A manual check confirms a shared-package update from the source's answer")
struct SharedPackageManualConfirmationTests {
    @Test func obsidianPackageReadAsCurrentConfirmsAlthoughTheInstallerBundleStaysOld() async throws {
        let installerBundle = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Obsidian.app"), name: "Obsidian",
                                              bundleIdentifier: "md.obsidian", version: "1.13.7", buildVersion: "1.13.7",
                                              installDate: nil, updateDate: nil, isManagedByBrew: false)
        let handoff = ManualOutdatedApp(name: "Obsidian", path: installerBundle.path, installedVersion: "1.14.2",
                                        availableVersion: "1.14.3", source: .obsidian, bundleIdentifier: "md.obsidian",
                                        completionRequirement: .init(version: "1.14.3", field: .sharedPackage, scheme: .semver))
        let checker = VendorUpdateCompletionChecker(readApplication: { _ in installerBundle }, checkSource: { _, _ in .upToDate })

        #expect(try await checker.check(handoff).outcome == .confirmed)
    }

    @Test func ownBundleTargetsStillRequireTheBundleToReachThem() async throws {
        let bundle = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                     bundleIdentifier: "com.example.app", version: "1.0", buildVersion: "100",
                                     installDate: nil, updateDate: nil, isManagedByBrew: false)
        let handoff = ManualOutdatedApp(name: "Example", path: bundle.path, installedVersion: "1.0 (100)",
                                        availableVersion: "1.0 (101)", source: .sparkle, bundleIdentifier: "com.example.app",
                                        completionRequirement: .init(version: "101", field: .buildVersion, scheme: .numericBuild))
        let checker = VendorUpdateCompletionChecker(readApplication: { _ in bundle }, checkSource: { _, _ in .upToDate })

        #expect(try await checker.check(handoff).outcome == .unconfirmed(.targetNotReached))
    }
}
