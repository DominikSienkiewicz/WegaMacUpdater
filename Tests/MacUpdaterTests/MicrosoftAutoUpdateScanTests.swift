import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Microsoft AutoUpdate scan evidence")
struct MicrosoftAutoUpdateScanTests {
    @Test func queryRunsOnceForTwoOfficeCopiesAndNeitherIsDeclaredCurrent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MicrosoftScanRunner()
        let report = await scanner(root: fixture.root, updater: fixture.updater, runner: runner).scanReport()
        let checks = report.installations.filter { $0.bundleIdentifier == "com.microsoft.Word" }
        #expect(checks.count == 2)
        #expect(await runner.requests.count == 1)
        #expect(report.apps.isEmpty)
        for check in checks {
            #expect(check.sources.contains(.init(source: "Microsoft AutoUpdate", outcome: .notChecked)))
            #expect(check.microsoftAutoUpdate?.status == .noUpdatesReported)
            #expect(check.microsoftAutoUpdate?.applicationID == "MSWD2019")
            #expect(check.lastSuccessfulCheck == nil)
        }
    }

    @Test func structuredEvidenceSurvivesSnapshotEncodingWithoutCreatingUpdates() throws {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/wega-test-fixtures/Word.app"), name: "Word",
            bundleIdentifier: "com.microsoft.Word", version: "16.28", installDate: nil, updateDate: nil, isManagedByBrew: false)
        let existing = ManualScanReport(apps: [], failedChecks: 0,
            installations: [.init(app: app, sources: [], checkedAt: Date())])
        let report = MicrosoftAutoUpdateReport(status: .noUpdatesReported, updaterVersion: "4.85")
            .applying(to: existing, applications: [app])
        let check = try #require(report.installations.first)
        let restored = try JSONDecoder().decode(InstallationCheck.self, from: JSONEncoder().encode(check))
        #expect(restored.microsoftAutoUpdate?.status == .noUpdatesReported)
        #expect(restored.microsoftAutoUpdate?.updaterVersion == "4.85")
        #expect(restored.status(for: app) == .notChecked)
        #expect(report.apps.isEmpty)
    }

    @Test func commandFailureBecomesIncompleteScanEvidence() throws {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/wega-test-fixtures/Word.app"), name: "Word",
            bundleIdentifier: "com.microsoft.Word", version: "16.28", installDate: nil, updateDate: nil, isManagedByBrew: false)
        let existing = ManualScanReport(apps: [], failedChecks: 0,
            installations: [.init(app: app, sources: [], checkedAt: Date())])
        let report = MicrosoftAutoUpdateReport(status: .failed).applying(to: existing, applications: [app])
        #expect(report.failedChecks == 1)
        #expect(report.uncheckedSources == ["Microsoft AutoUpdate · Word"])
        #expect(report.installations.first?.microsoftAutoUpdate?.status == .failed)
        #expect(report.installations.first?.status(for: app) == .failed)
    }

    @Test func absentOptionalUpdaterLeavesUnknownEvidenceWithoutASourceFailure() throws {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/wega-test-fixtures/Word.app"), name: "Word",
            bundleIdentifier: "com.microsoft.Word", version: "16.28", installDate: nil, updateDate: nil, isManagedByBrew: false)
        let existing = ManualScanReport(apps: [], failedChecks: 0,
            installations: [.init(app: app, sources: [], checkedAt: Date())])
        let report = MicrosoftAutoUpdateReport(status: .notInstalled).applying(to: existing, applications: [app])
        #expect(report.failedChecks == 0)
        #expect(report.uncheckedSources.isEmpty)
        #expect(report.installations.first?.microsoftAutoUpdate?.status == .notInstalled)
        #expect(report.installations.first?.sources == [.init(source: "Microsoft AutoUpdate", outcome: .notChecked)])
        #expect(MicrosoftAutoUpdateHandoff.destination(for: app,
            updaterURL: URL(fileURLWithPath: "/wega-test-fixtures/missing-MAU.app")) == MicrosoftAutoUpdateSupport.supportURL)
    }

    private func scanner(root: URL, updater: URL, runner: MicrosoftScanRunner) -> ManualUpdateScanner {
        ManualUpdateScanner(
            brewService: BrewService(locator: BinaryLocator(brewCandidates: []), runner: runner),
            scanDirectories: [root.appendingPathComponent("Applications")], caskCacheURL: root.appendingPathComponent("casks.json"),
            dependencies: .init(
                selfUpdateChecker: WegaSelfUpdateChecker(client: FakeHTTP.client(status: 503)),
                javaRuntimeDirectories: [], adobeUninstallDirectory: root.appendingPathComponent("no-adobe"),
                sparkleChecker: SparkleUpdateChecker(feedOverrides: [:]),
                microsoftAutoUpdateClient: .init(runner: runner, applicationURL: updater)
            )
        )
    }

    private func makeFixture() throws -> (root: URL, updater: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in ["Word.app", "Word Copy.app"] {
            let contents = root.appendingPathComponent("Applications/" + name + "/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try plist(["CFBundleIdentifier": "com.microsoft.Word", "CFBundleShortVersionString": "16.28"])
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let updater = root.appendingPathComponent("MAU.app")
        let executable = updater.appendingPathComponent("Contents/MacOS/msupdate")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try plist(["CFBundleIdentifier": "com.microsoft.autoupdate2", "CFBundleShortVersionString": "4.85"])
            .write(to: updater.appendingPathComponent("Contents/Info.plist"))
        try CaskDatabaseCache(fileURL: root.appendingPathComponent("casks.json")).save([])
        return (root, updater)
    }

    private func plist(_ values: [String: String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
}

private actor MicrosoftScanRunner: ProcessRunning {
    private(set) var requests: [ProcessRequest] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        return .init(exitCode: 0, stdout: "No updates available", stderr: "")
    }
    nonisolated func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
