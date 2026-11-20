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

    @Test func staleVendorTokensCoverNotInstalledAndAlreadyCurrentCasksOnly() {
        let logi = BrewOutdatedItem(name: "logi-options+", installedVersions: ["1"], currentVersion: "2")
        let warp = BrewOutdatedItem(name: "cloudflare-warp", installedVersions: ["1"], currentVersion: "2")
        let firefox = BrewOutdatedItem(name: "firefox", installedVersions: ["1"], currentVersion: "2")
        let logiAt = { (version: String) in check(bundleIdentifier: "com.logi.optionsplus", version: version) }

        #expect(ServiceVendorUpdatePolicy.staleVendorTokens(outdated: [logi, firefox], installationChecks: [])
                == ["logi-options+"], "not installed, and a non-vendor cask is never touched")
        #expect(ServiceVendorUpdatePolicy.staleVendorTokens(outdated: [logi], installationChecks: [logiAt("1")]).isEmpty,
                "installed below the target stays")
        #expect(ServiceVendorUpdatePolicy.staleVendorTokens(outdated: [logi], installationChecks: [logiAt("2")])
                == ["logi-options+"])
        #expect(ServiceVendorUpdatePolicy.staleVendorTokens(outdated: [logi], installationChecks: [logiAt("3")])
                == ["logi-options+"])
        #expect(ServiceVendorUpdatePolicy.staleVendorTokens(
            outdated: [logi, warp], installationChecks: [logiAt("1")]
        ) == ["cloudflare-warp"], "each token is judged by its own profile")
        let noTarget = BrewOutdatedItem(name: "logi-options+", installedVersions: ["1"], currentVersion: nil)
        #expect(ServiceVendorUpdatePolicy.staleVendorTokens(outdated: [noTarget], installationChecks: [logiAt("1")]).isEmpty)
    }

    private func check(bundleIdentifier: String, version: String = "1") -> InstallationCheck {
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Some.app"), name: "Some", bundleIdentifier: bundleIdentifier,
            version: version, installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        return InstallationCheck(app: app, sources: [], checkedAt: Date(timeIntervalSince1970: 1))
    }
}
