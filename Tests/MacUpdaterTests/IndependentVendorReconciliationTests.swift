import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Vendor and Homebrew update rows retain the newest version once")
struct IndependentVendorReconciliationTests {
    @Test(arguments: ["2.0.0", "3.0.0"])
    func vendorAtOrAheadOfBrewRepresentsTheInstallationOnce(brewVersion: String) {
        let vendor = row()
        let result = UpdatePlanner.reconciledUpdates(items: items(version: brewVersion), manual: [vendor])
        #expect(result.items.isEmpty)
        #expect(result.manual == [vendor])
    }

    @Test func aNewerBrewTargetIsNeverDowngradedToAnOlderVendorTarget() {
        let packages = items(version: "4.0.0")
        let result = UpdatePlanner.reconciledUpdates(items: packages, manual: [row()])
        #expect(result.items == packages)
        #expect(result.manual.isEmpty)
    }

    @Test func nameMatchesAndUnverifiedOwnershipCannotSuppressPackageRows() {
        var noAlias = row()
        noAlias.caskPolicyToken = nil
        var differentOwner = row()
        differentOwner.origin = .manual
        for vendor in [noAlias, differentOwner] {
            let result = UpdatePlanner.reconciledUpdates(items: items(), manual: [vendor])
            #expect(result.items == items())
            #expect(result.manual == [vendor])
        }
    }

    @Test func unknownVersionsAndIndependentObsidianPackagesRemainVisible() {
        var obsidian = row()
        obsidian.source = .obsidian
        obsidian.completionRequirement = .init(version: "3.0.0", field: .sharedPackage, scheme: .semver)
        for (version, vendor) in [("unknown", row()), ("2.0.0", obsidian)] {
            let packages = items(version: version)
            let result = UpdatePlanner.reconciledUpdates(items: packages, manual: [vendor])
            #expect(result.items == packages)
            #expect(result.manual == [vendor])
        }
    }

    @Test func aFormulaWithTheSameNameIsNotAnApplicationDuplicate() {
        let formula = OutdatedItem(key: "f:vendor-fixture", name: "vendor-fixture", from: "1.0.0", to: "2.0.0", kind: .formula)
        let result = UpdatePlanner.reconciledUpdates(items: [formula], manual: [row()])
        #expect(result.items == [formula])
        #expect(result.manual == [row()])
    }

    @Test func newerSparkleEvidenceSurvivesAnOlderCaskDriftRow() {
        var sparkle = row()
        sparkle.source = .sparkle
        var cask = row()
        cask.source = .cask(token: "vendor-fixture")
        cask.availableVersion = "2.0.0"
        for candidates in [[sparkle, cask], [cask, sparkle]] {
            #expect(UpdatePlanner.dedupedByPriority(candidates) == [sparkle])
        }
    }

    @Test func aRollbackRetryKeepsItsExplicitRecoveryAction() {
        var sparkle = row()
        sparkle.source = .sparkle
        var retry = row()
        retry.source = .cask(token: "vendor-fixture")
        retry.availableVersion = "2.0.0"
        retry.rolledBack = true
        #expect(UpdatePlanner.dedupedByPriority([sparkle, retry]) == [retry])
    }

    @Test func menuBarCountsTheLatestVendorUpdateOnceAndKeepsRawBrewEvidence() async {
        let result = await checker().availableUpdateCount()
        #expect(result.total == 1)
        #expect(result.outdatedDisplayNames() == ["Vendor fixture"])
        #expect(result.brew?.casks.count == 1)
        #expect(result.manualApps == [row()])
        #expect(result.removingUpgradedCasks(["unrelated"]).total == 1)
    }

    @Test func aCompletedBrewUpdateClearsOnlyVendorTargetsItReached() {
        var newer = row()
        newer.availableVersion = "5.0.0"
        var obsidian = row()
        obsidian.source = .obsidian
        obsidian.completionRequirement = .init(version: "3.0.0", field: .sharedPackage, scheme: .semver)
        for vendor in [row(), newer, obsidian] {
            let scan = MenuBarScanResult(brew: brew(version: "4.0.0"), mas: [], npm: [], manualApps: [vendor],
                                        failedChecks: 0, scannedAt: Date(), total: 1)
            let result = scan.removingUpgradedCasks(["vendor-fixture"])
            let expected = vendor == row() ? [] : [vendor]
            #expect(result.manualApps == expected)
            #expect(result.total == expected.count)
        }
    }

    @Test func missingOrOpaqueBuildComponentsDoNotCreateAFalseOrdering() {
        for version in ["3.invalid.0", "3.0.0,opaque", "3.0.0,99", "3.0.0.99"] {
            let packages = items(version: version)
            let result = UpdatePlanner.reconciledUpdates(items: packages, manual: [row()])
            #expect(result.items == packages)
            #expect(result.manual == [row()])
        }
    }

    @Test func skippingTheLatestVendorVersionDoesNotRevealAnOlderBrewOffer() async {
        let policies: [String: UpdatePolicy] = ["c:vendor-fixture": .skipped(version: "3.0.0")]
        let result = await checker().availableUpdateCount(policies: policies)
        #expect(result.total == 0)
        #expect(result.outdatedDisplayNames(policies: policies).isEmpty)
    }

    private func items(version: String = "2.0.0") -> [OutdatedItem] {
        UpdatePlanner.outdatedItems(brew: brew(version: version), mas: [], npm: [])
    }

    private func brew(version: String = "2.0.0") -> BrewOutdated {
        BrewOutdated(formulae: [], casks: [.init(name: "vendor-fixture", installedVersions: ["1.0.0"], currentVersion: version)])
    }

    private func row() -> ManualOutdatedApp {
        ManualOutdatedApp(name: "Vendor fixture", path: URL(fileURLWithPath: "/fixture/Chrome.app"),
                          installedVersion: "1.0.0", availableVersion: "3.0.0", source: .chrome, origin: .brew,
                          bundleIdentifier: "com.example.vendor-fixture", caskPolicyToken: "vendor-fixture")
    }

    private func checker() -> MenuBarUpdateChecker {
        MenuBarUpdateChecker(brewService: ReconciliationBrew(outdated: brew()), masService: ReconciliationMas(),
                             npmService: ReconciliationNpm(), scanner: ReconciliationScanner(apps: [row()]),
                             operations: OperationCoordinator())
    }
}

private struct ReconciliationBrew: BrewOutdatedProviding {
    let outdated: BrewOutdated
    func outdatedGreedy() async throws -> BrewOutdated { outdated }
}
private struct ReconciliationMas: MasOutdatedProviding {
    func outdated() async throws -> [MasOutdatedApp] { [] }
}
private struct ReconciliationNpm: NpmOutdatedProviding {
    func outdated() async throws -> [NpmGlobalOutdated] { [] }
}
private struct ReconciliationScanner: ManualScanning {
    let apps: [ManualOutdatedApp]
    func scan(brewOutdatedCasks: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int) { (apps, 0) }
}
