import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Cask policies across update routes")
struct CaskPolicyRouteTests {
    private let managedPath = URL(fileURLWithPath: "/Applications/Example.app")

    private func row(path: URL, source: ManualOutdatedApp.UpdateSource = .cask(token: "example")) -> ManualOutdatedApp {
        ManualOutdatedApp(
            name: "Example", path: path, installedVersion: "1.0", availableVersion: "2.0",
            source: source, origin: .brew, bundleIdentifier: "com.example.app"
        )
    }

    @Test func undoPinSuppressesTheMetadataRepairRoute() {
        let rows = UpdatePlanner.attachingCaskPolicies(
            to: [row(path: managedPath)], appPaths: ["example": managedPath]
        )
        #expect(UpdatePlanner.applyPolicies(rows, policies: ["c:example": .pinned(version: "1.0")]).isEmpty)
        #expect(UpdatePlanner.applyPolicies(rows, policies: [:]).count == 1)
    }

    @Test func caskPoliciesAlsoApplyToTheVendorRouteButNotAnotherCopy() {
        let otherPath = URL(fileURLWithPath: "/Users/test/Applications/Example.app")
        let rows = UpdatePlanner.attachingCaskPolicies(
            to: [row(path: managedPath, source: .sparkle), row(path: otherPath, source: .sparkle)],
            appPaths: ["example": managedPath]
        )
        for policy in [UpdatePolicy.ignored, .pinned(version: "1.0"), .skipped(version: "2.0")] {
            #expect(UpdatePlanner.applyPolicies(rows, policies: ["c:example": policy]).map(\.path) == [otherPath])
        }
    }

    @Test func aNameOrTokenMatchWithoutAResolvedPathDoesNotInheritPolicy() {
        let rows = UpdatePlanner.attachingCaskPolicies(to: [row(path: managedPath)], appPaths: [:])
        #expect(UpdatePlanner.applyPolicies(rows, policies: ["c:example": .ignored]).count == 1)
    }

    @Test func theAssociationSurvivesPersistenceAndManualPoliciesStillApply() throws {
        let rows = UpdatePlanner.attachingCaskPolicies(
            to: [row(path: managedPath)], appPaths: ["example": managedPath]
        )
        let restored = try JSONDecoder().decode([ManualOutdatedApp].self, from: JSONEncoder().encode(rows))
        #expect(UpdatePlanner.applyPolicies(restored, policies: ["c:example": .pinned(version: "1.0")]).isEmpty)
        #expect(UpdatePlanner.applyPolicies(restored, policies: [rows[0].policyKey: .ignored]).isEmpty)
    }

    @Test func ambiguousPackageOwnershipDoesNotSilenceAnInstallation() {
        let rows = UpdatePlanner.attachingCaskPolicies(
            to: [row(path: managedPath)], appPaths: ["example": managedPath, "other": managedPath]
        )
        #expect(UpdatePlanner.applyPolicies(rows, policies: ["c:example": .ignored]).count == 1)
    }

    @Test func installationStatusUsesTheSameCaskPinAsTheVendorRow() {
        let app = ApplicationInfo(path: managedPath, name: "Example", bundleIdentifier: "com.example.app",
                                  version: "1.0", installDate: nil, updateDate: nil, isManagedByBrew: true)
        let time = Date()
        var check = InstallationCheck(app: app, sources: [
            .init(source: "Sparkle", result: .outdated(row(path: managedPath, source: .sparkle)))
        ], checkedAt: time)
        check.caskToken = "example"
        #expect(check.status(for: app, policies: ["c:example": .pinned(version: "1.0")], now: time) == .excluded)
        #expect(check.status(for: app, now: time) == .updateAvailable)
    }

    @Test func aNewerVendorOfferKeepsTheResolvedPolicyAssociation() async throws {
        var item = row(path: managedPath, source: .sparkle)
        item.caskPolicyToken = "example"
        let app = ApplicationInfo(path: managedPath, name: item.name, bundleIdentifier: item.bundleIdentifier,
                                  version: "1.0", installDate: nil, updateDate: nil, isManagedByBrew: true)
        let newer = row(path: managedPath, source: .sparkle)
        let checker = VendorUpdateCompletionChecker(readApplication: { _ in app }, checkSource: { _, _ in .outdated(newer) })
        let result = try await checker.check(item)
        guard case .stillOutdated(let update) = result.outcome else { Issue.record("Expected the vendor offer"); return }
        #expect(update.caskPolicyToken == "example")
        #expect(UpdatePlanner.applyPolicies([update], policies: ["c:example": .pinned(version: "1.0")]).isEmpty)
    }

    @Test func legacyRowsWithoutAnAliasRemainReadable() throws {
        let data = try JSONEncoder().encode(row(path: managedPath))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "caskPolicyToken")
        let restored = try JSONDecoder().decode(ManualOutdatedApp.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.caskPolicyToken == nil)
    }
}
