import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Service vendor handoffs honor verified package ownership")
struct ServiceVendorPackageOwnershipTests {
    @Test func verifiedPackageOwnerProvidesAHandoffWithoutADirectAppArtifact() throws {
        let check = installation(path: "/Applications/logioptionsplus.app", verified: true)
        let rows = ServiceVendorUpdatePolicy.managedUpdates(items: [update], appPaths: [:], installationChecks: [check])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.path == check.path)
        #expect(row.bundleIdentifier == check.bundleIdentifier)
        #expect(row.caskPolicyToken == "logi-options+")
        #expect(row.completionRequirement == .init(version: "2"))
    }

    @Test func unconfirmedPackageCandidateCannotProvideAnActionablePath() {
        let check = installation(path: "/Applications/logioptionsplus.app", verified: false)
        #expect(ServiceVendorUpdatePolicy.managedUpdates(items: [update], appPaths: [:], installationChecks: [check]).isEmpty)
    }

    @Test func multipleVerifiedOwnersRemainUnresolved() {
        let checks = [installation(path: "/Applications/logioptionsplus.app", verified: true),
                      installation(path: "/Users/test/Applications/logioptionsplus.app", verified: true)]
        #expect(ServiceVendorUpdatePolicy.managedUpdates(items: [update], appPaths: [:], installationChecks: checks).isEmpty)
    }

    private var update: OutdatedItem {
        OutdatedItem(key: "c:logi-options+", name: "logi-options+", from: "1", to: "2", kind: .cask)
    }

    private func installation(path: String, verified: Bool) -> InstallationCheck {
        let app = ApplicationInfo(path: URL(fileURLWithPath: path), name: "Logi Options+", bundleIdentifier: "com.logi.optionsplus",
                                  version: "1", installDate: nil, updateDate: nil, isManagedByBrew: verified, caskToken: "logi-options+")
        var check = InstallationCheck(app: app, sources: [], checkedAt: Date())
        if verified { check.caskToken = "logi-options+" }
        else { check.unconfirmedCaskToken = "logi-options+" }
        return check
    }
}
