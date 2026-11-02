import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Service applications use their vendor update mechanism")
struct ServiceVendorUpdatePolicyTests {
    @Test(arguments: [
        ("com.cloudflare.1dot1dot1dot1.macos", "cloudflare-warp", ServiceVendorUpdateProfile.cloudflareWarp),
        ("com.logi.optionsplus", "logi-options+", ServiceVendorUpdateProfile.logiOptionsPlus),
        ("com.bitdefender.antivirusformac", "bitdefender", ServiceVendorUpdateProfile.bitdefender)
    ])
    func exactIdentityProvidesAnExplicitVendorHandoff(bundleID: String, token: String, expected: ServiceVendorUpdateProfile) {
        let app = application(bundleID: bundleID, token: token)
        #expect(ServiceVendorUpdateProfile.profile(for: app) == expected)
        #expect(expected.updateActionKind == .launchApp)
        #expect(expected.supportURL?.scheme == "https")
        #expect(CatalogReporting.hasKnownUpdateSource(app, catalog: .shared))
    }

    @Test(arguments: ["com.example.warp", "com.logi.optionsplus.helper", "com.bitdefender.agentui", "com.bitdefender.vpn"])
    func namesNeverAttributeUnrelatedApps(bundleID: String) {
        let app = application(bundleID: bundleID, token: nil)
        #expect(ServiceVendorUpdateProfile.profile(for: app) == nil)
    }

    @Test(arguments: ["cloudflare-warp", "logi-options+", "homebrew/cask/cloudflare-warp"])
    func serviceCasksCannotBypassTheVendorThroughHomebrew(token: String) {
        #expect(ManualOutdatedApp.UpdateSource.cask(token: token).updateActionKind == .launchApp)
        #expect(ServiceVendorUpdatePolicy.eligibleKeys(["c:" + token, "c:iterm2", "f:cloudflare-warp"]) == ["c:iterm2", "f:cloudflare-warp"])
        let profile = CaskArtifactProfile(token: token, artifacts: [CaskArtifact(kind: .app)])
        let download = CaskDownloadInfo(token: token, url: "https://example.invalid/app.dmg", sha256: String(repeating: "a", count: 64))
        #expect(BackgroundUpdateEligibility.evaluate(profile: profile, download: download) != .eligible)
        #expect(BackgroundUpdatePlanner.eligibleTokens(.init(candidates: [token], profiles: [token: profile], downloads: [token: download], optedIn: [token], runningProcessTokens: [], policies: [:])).isEmpty)
        let context = BackgroundUpdateConsentContext(candidateTokens: [token], resolvedAppTokens: [token], runningTokens: [], policies: [:])
        #expect(BackgroundUpdateConsentQualification.evaluate(token: token, profile: nil, download: nil, context: context) != .metadataUnavailable)
    }

    @Test func serviceBundlesDoNotBecomeGenericCaskAdoptionCandidates() {
        let app = application(bundleID: "com.cloudflare.1dot1dot1dot1.macos", token: "cloudflare-warp")
        #expect(ManualUpdateScanner.caskVersionCheck(app: app, brewTrackedVersion: nil, latestCaskVersions: ["cloudflare-warp": "2"]) == nil)
    }

    @Test func scanKeepsServiceFreshnessUnknownWithoutCreatingAnUpdate() {
        let app = application(bundleID: "com.logi.optionsplus", token: nil)
        let now = Date(timeIntervalSince1970: 10)
        let report = ManualScanReport(apps: [], observations: [], installations: [app], checkedAt: now)
        #expect(report.apps.isEmpty)
        #expect(report.failedChecks == 0)
        #expect(report.installations.first?.sources == [.init(source: "Logi Options+", outcome: .notChecked)])
        #expect(report.installations.first?.status(for: app, now: now) == .notChecked)
        let cached = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .current)], checkedAt: now)
        #expect(cached.status(for: app, now: now) == .notChecked)
        #expect(cached.lastSuccessfulCheck == nil)
    }

    @Test func availableBrewEvidenceCreatesOnlyAnExactlyResolvedVendorRow() throws {
        let app = application(bundleID: "com.logi.optionsplus", token: "logi-options+")
        let item = OutdatedItem(key: "c:logi-options+", name: "logi-options+", from: "1", to: "2", kind: .cask)
        let check = InstallationCheck(app: app, sources: [], checkedAt: Date())
        let rows = ServiceVendorUpdatePolicy.managedUpdates(items: [item], appPaths: [item.name: app.path], installationChecks: [check])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.path == app.path)
        #expect(row.bundleIdentifier == app.bundleIdentifier)
        #expect(row.completionRequirement == .init(version: "2"))
        #expect(ServiceVendorUpdatePolicy.managedUpdates(items: [], appPaths: [item.name: app.path], installationChecks: [check]).isEmpty)
        #expect(ServiceVendorUpdatePolicy.managedUpdates(items: [item], appPaths: [item.name: app.path], installationChecks: []).isEmpty)
    }

    @Test func serviceCompletionRequiresLocalVersionEvidenceWithoutQueryingAnUnrelatedSource() async throws {
        let app = application(bundleID: "com.logi.optionsplus", token: "logi-options+")
        let pending = ManualOutdatedApp(name: app.name, path: app.path, installedVersion: "0", availableVersion: "1",
                                       source: .cask(token: "logi-options+"), origin: .brew, bundleIdentifier: app.bundleIdentifier,
                                       completionRequirement: .init(version: "1"))
        let checker = VendorUpdateCompletionChecker(readApplication: { _ in app }, checkSource: { _, _ in
            Issue.record("A service handoff verifies the exact local target without pretending to query a vendor feed")
            return .notApplicable
        })
        #expect(try await checker.check(pending).outcome == .confirmed)
        var unknown = pending
        unknown.completionRequirement = nil
        #expect(try await checker.check(unknown).outcome == .unconfirmed(.unknownTarget))
        var newer = pending
        newer.completionRequirement = .init(version: "2")
        #expect(try await checker.check(newer).outcome == .unconfirmed(.targetNotReached))
    }

    private func application(bundleID: String, token: String?) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Service.app"), name: "Cloudflare WARP",
                        bundleIdentifier: bundleID, version: "1", installDate: nil, updateDate: nil,
                        isManagedByBrew: false, caskToken: token)
    }
}
