import Foundation
import Testing

@testable import MacUpdaterCore

@Suite("Bitdefender product and malware definition evidence")
struct BitdefenderSupportTests {
    @Test func recognizesTheAntivirusBundleAndKeepsItsProductFieldsSeparate() throws {
        let status = try #require(BitdefenderSupport.status(for: application()))

        #expect(status.installedProductVersion == "10.3.6")
        #expect(status.installedProductBuild == "10.3.6.18")
        #expect(status.productFreshness == .unknown)
        #expect(status.malwareDefinitionsFreshness == .unknown)
    }

    @Test(arguments: [
        "com.bitdefender.agentui",
        "com.bitdefender.vpn",
        "com.bitdefender.virusscannerplus",
        "com.bitdefender.BitdefenderVirusScanner",
        "example.bitdefender.antivirusformac"
    ])
    func doesNotConfuseOtherProductsWithAntivirus(bundleIdentifier: String) {
        #expect(BitdefenderSupport.status(for: application(bundleIdentifier: bundleIdentifier)) == nil)
    }

    @Test func theApplicationNameAloneDoesNotProveProductIdentity() {
        #expect(BitdefenderSupport.status(for: application(bundleIdentifier: nil)) == nil)
    }

    @Test func absentBundleVersionsRemainUnknownWithoutInventingALatestVersion() throws {
        let status = try #require(BitdefenderSupport.status(for: application(version: nil, build: nil)))

        #expect(status.installedProductVersion == nil)
        #expect(status.installedProductBuild == nil)
        #expect(status.productFreshness == .unknown)
        #expect(status.malwareDefinitionsFreshness == .unknown)
    }

    @Test func emptyBundleVersionFieldsAreNotPresentedAsEvidence() throws {
        let status = try #require(BitdefenderSupport.status(for: application(version: " ", build: "\n")))

        #expect(status.installedProductVersion == nil)
        #expect(status.installedProductBuild == nil)
    }

    @Test func anAvailableBuildDoesNotBecomeTheProductVersionOrDefinitionVersion() throws {
        let status = try #require(BitdefenderSupport.status(for: application(version: nil)))

        #expect(status.installedProductVersion == nil)
        #expect(status.installedProductBuild == "10.3.6.18")
        #expect(status.malwareDefinitionsFreshness == .unknown)
    }

    @Test func aRecentBundleModificationDoesNotProveProductOrDefinitionFreshness() throws {
        var app = application()
        app.updateDate = Date()
        let status = try #require(BitdefenderSupport.status(for: app))

        #expect(status.productFreshness == .unknown)
        #expect(status.malwareDefinitionsFreshness == .unknown)
    }

    @Test func recognizedAntivirusOffersTheOfficialProductUpdateInstructions() throws {
        let status = try #require(BitdefenderSupport.status(for: application()))

        #expect(status.supportURL?.absoluteString == "https://www.bitdefender.com/consumer/support/answer/32547/")
    }

    private func application(
        bundleIdentifier: String? = "com.bitdefender.antivirusformac",
        version: String? = "10.3.6",
        build: String? = "10.3.6.18"
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Bitdefender/AntivirusforMac.app"),
            name: "AntivirusforMac", bundleIdentifier: bundleIdentifier, version: version,
            buildVersion: build, installDate: nil, updateDate: nil, isManagedByBrew: false
        )
    }
}
