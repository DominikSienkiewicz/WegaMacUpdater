import Foundation
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class ScanStatusPipelineTests: XCTestCase {
    func testForegroundScanPublishesAndPersistsTheDetailedReportWithoutLosingLastSuccess() async throws {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                  bundleIdentifier: "com.example.status", version: "1", installDate: nil, updateDate: nil,
                                  isManagedByBrew: false, caskToken: nil)
        let time = Date()
        let failed = InstallationCheck(app: app, sources: [.init(source: "Sparkle", outcome: .failed)], checkedAt: time)
        let report = ManualScanReport(apps: [], failedChecks: 1, uncheckedSources: ["Sparkle · Example"], installations: [failed])
        let runner = ScanStoreRuntimeProcessRunner { request in
            let output: String
            if request.arguments.contains("--json=v2") { output = "{\"formulae\":[],\"casks\":[]}" }
            else if request.arguments.contains("--json") { output = "{}" }
            else { output = "" }
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        var dependencies = harness.store.dependencies
        dependencies.detailedManualScan = { _, _ in report }
        let store = ScanStore(resultStore: ScanResultStore(io: harness.snapshots), dependencies: dependencies)
        store.attach(model: try XCTUnwrap(harness.store.model))
        let previous = InstallationCheck(app: app, sources: [.init(source: "Sparkle", outcome: .current)],
                                         checkedAt: time.addingTimeInterval(-60))
        store.installationChecks = [previous]

        await store.runCheck()

        XCTAssertEqual(store.installationChecks.first?.status(for: app), .failed)
        XCTAssertEqual(store.installationChecks.first?.lastSuccessfulCheck, previous.checkedAt)
        XCTAssertEqual(store.failedSources, 1)
        XCTAssertFalse(store.lastScanComplete)
        let snapshot = try JSONDecoder().decode(ScanSnapshot.self, from: XCTUnwrap(harness.snapshots.data))
        XCTAssertEqual(snapshot.installationChecks, store.installationChecks)
        XCTAssertEqual(snapshot.sources.manual, report.sourceReport)
        XCTAssertFalse(snapshot.isComplete)
    }
}
