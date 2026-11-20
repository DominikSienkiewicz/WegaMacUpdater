import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("A Homebrew record of a vendor app nobody installed is not an update")
struct ServiceVendorNotInstalledTests {
    @Test func completeScanWithoutAnyInstallationOfTheAppMeansNotInstalled() {
        #expect(ServiceVendorUpdatePolicy.isNotInstalled(token: "logi-options+", installationChecks: [], scanComplete: true))
        #expect(ServiceVendorUpdatePolicy.isNotInstalled(
            token: "logi-options+", installationChecks: [check(bundleIdentifier: "com.other.app")], scanComplete: true
        ))
    }

    @Test func anIncompleteScanProvesNothing() {
        #expect(!ServiceVendorUpdatePolicy.isNotInstalled(token: "logi-options+", installationChecks: [], scanComplete: false))
    }

    @Test func aCheckWithTheProfilesBundleIdentifierMeansInstalled() {
        #expect(!ServiceVendorUpdatePolicy.isNotInstalled(
            token: "logi-options+", installationChecks: [check(bundleIdentifier: "com.logi.optionsplus")], scanComplete: true
        ))
    }

    @Test func aTokenWithoutAVendorProfileIsNeverNotInstalled() {
        #expect(!ServiceVendorUpdatePolicy.isNotInstalled(token: "firefox", installationChecks: [], scanComplete: true))
    }

    @Test func everyProfileNamesTheBundleItIsMappedFrom() {
        for profile in [ServiceVendorUpdateProfile.cloudflareWarp, .bitdefender, .logiOptionsPlus] {
            #expect(ServiceVendorUpdateProfile.profile(bundleIdentifier: profile.bundleIdentifier) == profile)
        }
    }

    private func check(bundleIdentifier: String) -> InstallationCheck {
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Some.app"), name: "Some", bundleIdentifier: bundleIdentifier,
            version: "1", installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        return InstallationCheck(app: app, sources: [], checkedAt: Date(timeIntervalSince1970: 1))
    }
}
