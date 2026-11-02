import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Docker Desktop uses a supervised vendor update policy")
struct DockerDesktopUpdatePolicyTests {
    @Test(arguments: ["docker", "docker-desktop", "homebrew/cask/docker", "homebrew/cask/docker-desktop"])
    func dockerCaskDefaultsToItsOwnUpdater(token: String) {
        let source = ManualOutdatedApp.UpdateSource.cask(token: token)
        #expect(source.updateActionKind == .launchApp)
        #expect(source.supportsVendorCompletion)
        #expect(DockerDesktopUpdatePolicy.isDocker(token: token))
    }

    @Test func dockerRemainsDetectedButCannotEnterABulkPlanEvenFromStaleSelection() {
        let items = UpdatePlanner.outdatedItems(brew: .init(formulae: [
            .init(name: "docker", installedVersions: ["1"], currentVersion: "2")
        ], casks: [
            .init(name: "docker-desktop", installedVersions: ["4.50"], currentVersion: "4.51"),
            .init(name: "iterm2", installedVersions: ["1"], currentVersion: "2")
        ]), mas: [], npm: [])
        #expect(items.map(\.key) == ["f:docker", "c:docker-desktop", "c:iterm2"])
        #expect(UpdatePlanner.targets(from: DockerDesktopUpdatePolicy.batchItems(items), selectedKeys: Set(items.map(\.key)), filter: .all).map(\.key)
                == ["f:docker", "c:iterm2"])
        let plan = UpdatePlanner.plan(selectedKeys: DockerDesktopUpdatePolicy.eligibleKeys(
            ["c:docker-desktop", "c:homebrew/cask/docker", "c:iterm2", "f:docker"]))
        #expect(plan.caskNames == ["iterm2"])
        #expect(plan.formulaNames == ["docker"])
        #expect(plan.count == 2)
    }

    @Test func staleBackgroundConsentCannotOverrideDockerPolicy() {
        let tokens = ["docker", "docker-desktop", "homebrew/cask/docker", "iterm2"]
        let profiles = Dictionary(uniqueKeysWithValues: tokens.map { ($0, profile($0)) })
        let downloads = Dictionary(uniqueKeysWithValues: tokens.map { ($0, download($0)) })
        let candidates = BackgroundUpdatePlanner.eligibleTokens(.init(
            candidates: tokens, profiles: profiles, downloads: downloads, optedIn: Set(tokens),
            runningProcessTokens: [], policies: [:]
        ))
        #expect(candidates == ["iterm2"])
        #expect(BackgroundUpdateEligibility.evaluate(profile: profile("docker"), download: download("docker")) != .eligible)
        let context = BackgroundUpdateConsentContext(candidateTokens: Set(tokens), resolvedAppTokens: Set(tokens),
                                                     runningTokens: [], policies: [:])
        #expect(BackgroundUpdateConsentQualification.evaluate(token: "docker", profile: nil,
                                                              download: nil, context: context) != .metadataUnavailable)
    }

    @Test func managedDockerGetsAVerifiableVendorRowAtTheResolvedInstallation() throws {
        let path = URL(fileURLWithPath: "/Applications/Docker.app")
        let app = ApplicationInfo(path: path, name: "Docker", bundleIdentifier: "com.docker.docker",
                                  version: "4.50.0", buildVersion: "200", installDate: nil, updateDate: nil, isManagedByBrew: true)
        let check = InstallationCheck(app: app, sources: [], checkedAt: Date(timeIntervalSince1970: 1))
        let item = OutdatedItem(key: "c:docker-desktop", name: "docker-desktop", from: "4.50.0,200", to: "4.51.0,201", kind: .cask)
        let rows = DockerDesktopUpdatePolicy.managedUpdates(items: [item], appPaths: ["docker-desktop": path], installationChecks: [check])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.path == path)
        #expect(row.source == .cask(token: "docker-desktop"))
        #expect(row.origin == .brew)
        #expect(row.bundleIdentifier == "com.docker.docker")
        #expect(row.caskPolicyToken == "docker-desktop")
        #expect(row.completionRequirement == .init(version: "201", field: .buildVersion, scheme: .numericBuild))
        #expect(row.installedVersion == "4.50.0")
        #expect(DockerDesktopUpdatePolicy.managedUpdates(items: [item], appPaths: [:], installationChecks: [check]).isEmpty)
    }

    @Test func dockerCompletionRequiresTheExactTargetWithoutClaimingAVendorSourceCheck() async throws {
        let path = URL(fileURLWithPath: "/Applications/Docker.app")
        let pending = ManualOutdatedApp(name: "Docker", path: path, installedVersion: "4.50.0",
            availableVersion: "4.51.0,201", source: .cask(token: "docker-desktop"), origin: .brew,
            bundleIdentifier: "com.docker.docker", completionRequirement: .init(version: "201", field: .buildVersion, scheme: .numericBuild))
        let installed = ApplicationInfo(path: path, name: "Docker", bundleIdentifier: "com.docker.docker",
            version: "4.51.0", buildVersion: "201", installDate: nil, updateDate: nil, isManagedByBrew: true)
        let checker = VendorUpdateCompletionChecker(readApplication: { _ in installed }, checkSource: { _, _ in
            Issue.record("Docker handoff verifies the local target; it must not pretend to check a vendor feed")
            return .notApplicable
        })
        #expect(try await checker.check(pending).outcome == .confirmed)
        var newer = pending
        newer.completionRequirement = .init(version: "202", field: .buildVersion, scheme: .numericBuild)
        #expect(try await checker.check(newer).outcome == .unconfirmed(.targetNotReached))
        var unknown = pending
        unknown.completionRequirement = nil
        #expect(try await checker.check(unknown).outcome == .unconfirmed(.unknownTarget))
    }

    @Test func cachedVendorEvidenceKeepsItsResolvedHomebrewAlternative() {
        var vendor = ManualOutdatedApp(name: "Docker", path: URL(fileURLWithPath: "/Applications/Docker.app"),
            installedVersion: "4.50", availableVersion: "4.51", source: .sparkle, origin: .brew,
            bundleIdentifier: "com.docker.docker", caskPolicyToken: "docker-desktop")
        #expect(DockerDesktopUpdatePolicy.homebrewToken(for: vendor) == "docker-desktop")
        vendor.caskPolicyToken = nil
        #expect(DockerDesktopUpdatePolicy.homebrewToken(for: vendor) == nil)
        vendor.caskPolicyToken = "unrelated-app"
        #expect(DockerDesktopUpdatePolicy.homebrewToken(for: vendor) == nil)
    }

    @Test func unrelatedCasksKeepTheirExistingAction() {
        #expect(ManualOutdatedApp.UpdateSource.cask(token: "docker-toolbox").updateActionKind == .brewInstall(token: "docker-toolbox"))
        #expect(!DockerDesktopUpdatePolicy.isDocker(token: "docker-compose"))
    }

    private func profile(_ token: String) -> CaskArtifactProfile {
        .init(token: token, artifacts: [CaskArtifact(kind: .app)])
    }

    private func download(_ token: String) -> CaskDownloadInfo {
        .init(token: token, url: "https://example.invalid/app.dmg", sha256: String(repeating: "a", count: 64))
    }
}
