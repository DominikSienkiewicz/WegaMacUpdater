import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Background updates execute only the represented Homebrew offers")
struct IndependentVendorBackgroundTests {
    @Test(arguments: ["2.0.0", "3.0.0"])
    func aVendorOfferAtOrAheadOfBrewRemovesTheCaskFromAutomaticCandidates(brewVersion: String) {
        let result = scan(brewVersion: brewVersion, vendor: vendor())
        #expect(result.backgroundCaskCandidates.isEmpty)
        #expect(result.brew?.casks.count == 1, "Raw manager evidence remains available")
    }

    @Test func aNewerBrewOfferKeepsItsAutomaticCandidate() {
        #expect(scan(brewVersion: "4.0.0", vendor: vendor()).backgroundCaskCandidates == ["vendor-fixture"])
    }

    @Test func unverifiedOwnershipCannotSuppressAnAutomaticCandidate() {
        var unverified = vendor()
        unverified.caskPolicyToken = nil
        #expect(scan(brewVersion: "2.0.0", vendor: unverified).backgroundCaskCandidates == ["vendor-fixture"])
    }

    @Test func unknownOrIndependentPackageVersionsKeepTheirSeparateCaskOffer() {
        #expect(scan(brewVersion: "unknown", vendor: vendor()).backgroundCaskCandidates == ["vendor-fixture"])
        var obsidian = vendor()
        obsidian.source = .obsidian
        obsidian.completionRequirement = .init(version: "3.0.0", field: .sharedPackage, scheme: .semver)
        #expect(scan(brewVersion: "2.0.0", vendor: obsidian).backgroundCaskCandidates == ["vendor-fixture"])
    }

    private func scan(brewVersion: String, vendor: ManualOutdatedApp) -> MenuBarScanResult {
        MenuBarScanResult(
            brew: .init(formulae: [], casks: [.init(name: "vendor-fixture", installedVersions: ["1.0.0"], currentVersion: brewVersion)]),
            mas: [], npm: [], manualApps: [vendor], failedChecks: 0, scannedAt: Date(), total: 1
        )
    }

    private func vendor() -> ManualOutdatedApp {
        ManualOutdatedApp(name: "Vendor fixture", path: URL(fileURLWithPath: "/fixture/Background Vendor.app"),
                          installedVersion: "1.0.0", availableVersion: "3.0.0", source: .chrome, origin: .brew,
                          bundleIdentifier: "com.example.background-vendor", caskPolicyToken: "vendor-fixture")
    }
}
