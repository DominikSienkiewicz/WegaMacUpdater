import Foundation
import Testing
@testable import MacUpdaterCore

/// The background check counted raw `brew outdated --greedy`, which lists every self-updating
/// cask whose Caskroom record fell behind the app. On the reporting Mac that was 14 of 15
/// casks, among them `proton-mail` at 1.16.1 on disk against the cask's 1.16.0: the badge and
/// notification announced updates the window scan correctly hid, and an opted-in background
/// round could `brew upgrade` such a cask back to the older version.
@Suite("Background check hides casks already current on disk")
struct MenuBarDriftedCaskTests {
    private let outdated = BrewOutdated(formulae: [], casks: [
        .init(name: "proton-mail", installedVersions: ["1.15.1"], currentVersion: "1.16.0"),
        .init(name: "logi-options+", installedVersions: ["2.9.994631"], currentVersion: "2.9.1013853"),
        .init(name: "zed", installedVersions: ["1.26.2"], currentVersion: "1.27.0")
    ])
    private let infos = [
        BrewCaskInstallationInfo(token: "proton-mail", appArtifacts: ["Proton Mail.app"]),
        BrewCaskInstallationInfo(token: "logi-options+", appArtifacts: []),
        BrewCaskInstallationInfo(token: "zed", appArtifacts: ["Zed.app"])
    ]

    @Test func casksAlreadyCurrentOnDiskAreNeitherCountedNorOfferedInTheBackground() async {
        let result = await checker(infos: .success(infos)).availableUpdateCount()
        #expect(result.brew?.casks.map(\.name) == ["zed"])
        #expect(result.total == 1)
        #expect(result.backgroundCaskCandidates == ["zed"])
    }

    /// Without cask metadata the drift filter hides nothing: `proton-mail` stays although its app
    /// is current on disk. `logi-options+` still leaves, through the vendor-service rule
    /// (`ServiceVendorUpdatePolicy.staleVendorTokens`), which judges the scan's own copy at the
    /// cask's target and needs no cask metadata.
    @Test func unreadableCaskMetadataLeavesOnlyTheVendorRuleToHideACask() async {
        struct BrewInfoFailed: Error {}
        let result = await checker(infos: .failure(BrewInfoFailed())).availableUpdateCount()
        #expect(result.brew?.casks.map(\.name) == ["proton-mail", "zed"])
        #expect(result.total == 2)
    }

    private func checker(infos: Result<[BrewCaskInstallationInfo], Error>) -> MenuBarUpdateChecker {
        let onDisk = ["/Applications/Proton Mail.app": "1.16.1", "/Applications/Zed.app": "1.26.2"]
        return MenuBarUpdateChecker(
            brewService: DriftBrew(outdated: outdated, infos: infos),
            masService: NoMas(),
            npmService: NoNpm(),
            scanner: AttributingScanner(installations: [logiInstallation()]),
            operations: OperationCoordinator(),
            driftFilter: BrewCaskDriftFilter(
                applicationsDir: URL(fileURLWithPath: "/Applications", isDirectory: true),
                userApplicationsDir: URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true),
                readBundleVersion: { onDisk[$0.path] }
            )
        )
    }

    private func logiInstallation() -> InstallationCheck {
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/logioptionsplus.app"),
            name: "logioptionsplus",
            bundleIdentifier: "com.logi.optionsplus",
            version: "2.9.1013853",
            buildVersion: "2.9.1013853",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: true,
            caskToken: "logi-options+"
        )
        var check = InstallationCheck(app: app, sources: [], checkedAt: Date(timeIntervalSince1970: 0))
        check.caskToken = "logi-options+"
        return check
    }
}

private struct DriftBrew: BrewOutdatedProviding {
    let outdated: BrewOutdated
    let infos: Result<[BrewCaskInstallationInfo], Error>
    func outdatedGreedy() async throws -> BrewOutdated { outdated }
    func caskInstallationInfo(tokens: [String]) async throws -> [BrewCaskInstallationInfo] {
        try infos.get().filter { tokens.contains($0.token) }
    }
}

private struct NoMas: MasOutdatedProviding {
    func outdated() async throws -> [MasOutdatedApp] { [] }
}

private struct NoNpm: NpmOutdatedProviding {
    func outdated() async throws -> [NpmGlobalOutdated] { [] }
}

private struct AttributingScanner: ManualScanning {
    let installations: [InstallationCheck]
    func scan(brewOutdatedCasks: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int) { ([], 0) }
    func scanReport(brewOutdatedCasks: Set<String>) async -> ManualScanReport {
        ManualScanReport(apps: [], failedChecks: 0, installations: installations)
    }
}
