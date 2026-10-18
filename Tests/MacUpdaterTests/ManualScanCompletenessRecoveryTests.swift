import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Manual scan completeness recovery")
struct ManualScanCompletenessRecoveryTests {
    @Test func schemaTwoRetainsItsListsButCannotCertifyCompleteness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanResultStore(io: FileScanSnapshotIO(fileURL: root.appendingPathComponent("scan.json")))
        let app = ManualOutdatedApp(name: "Example", path: URL(fileURLWithPath: "/Applications/Example.app"),
                                    installedVersion: "1", availableVersion: "2", source: .sparkle)
        let scannedAt = Date(timeIntervalSince1970: 1000)
        let installation = ApplicationInfo(path: app.path, name: app.name, bundleIdentifier: nil, version: "1",
                                           installDate: nil, updateDate: nil, isManagedByBrew: false)
        let check = InstallationCheck(app: installation, sources: [.init(source: "Sparkle", outcome: .current)], checkedAt: scannedAt)
        var original = ScanSnapshot(scannedAt: scannedAt, brew: nil, mas: [], npm: [], manual: [app],
                                    sources: .init(manual: .init(outcome: .succeeded)),
                                    installationChecks: [check], vendorHandoffs: [app])
        original.schemaVersion = 2
        try store.save(original)

        let restored = try #require(store.load())

        #expect(restored.schemaVersion == ScanSnapshot.currentSchemaVersion)
        #expect(!restored.isComplete)
        #expect(restored.manual == original.manual)
        #expect(restored.scannedAt == scannedAt)
        #expect(restored.sources == original.sources)
        #expect(restored.installationChecks == original.installationChecks)
        #expect(restored.vendorHandoffs == original.vendorHandoffs)
    }

    @Test func missingOptionalDirectoriesAreNotOutagesButUnreadableLocationsAre() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("casks.json")
        try CaskDatabaseCache(fileURL: cache).save([])
        let notADirectory = root.appendingPathComponent("not-a-directory")
        try Data().write(to: notADirectory)
        let scanner = ManualUpdateScanner(
            brewService: BrewService(
                locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                runner: CompletenessRecoveryBrewRunner()
            ),
            scanDirectories: [root.appendingPathComponent("missing"), notADirectory], caskCacheURL: cache,
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(status: 503)),
                javaRuntimeDirectories: [], adobeUninstallDirectory: root.appendingPathComponent("no-adobe")
            )
        )

        let report = await scanner.scanReport()

        #expect(!report.uncheckedSources.contains(root.appendingPathComponent("missing").path))
        #expect(report.uncheckedSources.contains(notADirectory.path))
        #expect(report.uncheckedSources.contains("GitHub · Wega"))
        #expect(report.failedChecks == 2)
    }

    @Test func backgroundUpgradeRemovalPreservesTheIncompleteManualReport() async {
        let report = ManualScanReport(apps: [], failedChecks: 1, uncheckedSources: ["Sparkle · Example"])
        let result = await MenuBarUpdateChecker(
            brewService: CompletenessRecoveryBrew(), masService: CompletenessRecoveryMas(),
            npmService: CompletenessRecoveryNpm(), scanner: CompletenessRecoveryScanner(report: report),
            operations: OperationCoordinator()
        ).availableUpdateCount()

        #expect(result.total == 1)
        #expect(result.failedChecks == 1)
        #expect(result.sources.manual == report.sourceReport)
        let afterUpgrade = result.removingUpgradedCasks(["example"])
        #expect(afterUpgrade.total == 0)
        #expect(afterUpgrade.sources.manual == report.sourceReport)
        #expect(!afterUpgrade.sources.isComplete)
    }

    @Test func temporaryOutagesRetainTheirSourceNamesThroughPersistence() throws {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                  bundleIdentifier: nil, version: "1", installDate: nil, updateDate: nil,
                                  isManagedByBrew: false)
        let observations = [
            ManualCheckObservation(app: app, source: "Sparkle", result: .unavailable),
            ManualCheckObservation(app: app, source: "GitHub", result: .upToDate),
            ManualCheckObservation(app: app, source: "Adobe", result: .notApplicable)
        ]
        let report = ManualScanReport(apps: [], observations: observations, installations: [app], checkedAt: Date())
        let sources = ScanSourceReports(manual: report.sourceReport)
        let restored = try JSONDecoder().decode(ScanSourceReports.self, from: JSONEncoder().encode(sources))

        #expect(report.failedChecks == 1)
        #expect(report.uncheckedSources == ["Sparkle · Example"])
        #expect(!restored.isComplete)
        #expect(restored.errors == ["Sparkle · Example"])
    }

    @Test func manualFailurePrefixHasAnEnglishTranslation() {
        #expect(Translations.en["Nie udało się sprawdzić: %@"] == "Could not check: %@")
    }

    @Test func inapplicableSourcesAreExcludedButParserFailuresRemainIncomplete() {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                  bundleIdentifier: nil, version: "1", installDate: nil, updateDate: nil,
                                  isManagedByBrew: false)
        let report = ManualScanReport(apps: [], observations: [
            .init(app: app, source: "Sparkle", result: .notApplicable),
            .init(app: app, source: "GitHub", result: .failed)
        ], installations: [app], checkedAt: Date())

        #expect(report.failedChecks == 1)
        #expect(report.uncheckedSources == ["GitHub · Example"])
        #expect(!ScanSourceReports(manual: report.sourceReport).isComplete)
        #expect(ManualScanReport(apps: [], failedChecks: 0).sourceReport.outcome == .succeeded)
    }
}

private struct CompletenessRecoveryBrewRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: request.arguments.first == "list" ? "" : "{\"casks\":[]}", stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct CompletenessRecoveryBrew: BrewOutdatedProviding {
    func outdatedGreedy() async throws -> BrewOutdated {
        BrewOutdated(formulae: [], casks: [.init(name: "example", installedVersions: ["1"], currentVersion: "2")])
    }
}

private struct CompletenessRecoveryMas: MasOutdatedProviding {
    func outdated() async throws -> [MasOutdatedApp] { [] }
}

private struct CompletenessRecoveryNpm: NpmOutdatedProviding {
    func outdated() async throws -> [NpmGlobalOutdated] { [] }
}

private struct CompletenessRecoveryScanner: ManualScanning {
    let report: ManualScanReport

    func scan(brewOutdatedCasks: Set<String>) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        (report.apps, report.failedChecks)
    }

    func scanReport(brewOutdatedCasks: Set<String>) async -> ManualScanReport { report }
}
