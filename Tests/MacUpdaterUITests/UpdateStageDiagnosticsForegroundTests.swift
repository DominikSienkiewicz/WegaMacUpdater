import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

/// The foreground flow takes `UpgradeMutex.shared`, so it runs with the sequential XCTest
/// orchestration tests, separately from Swift Testing suites that exercise migration.
@MainActor
final class UpdateStageDiagnosticsForegroundTests: XCTestCase {
    func testForegroundRecordsPlanRescanAndVerdictWithoutAddingCommands() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foreground-diagnostics-\(UUID())")
        let store = DiagnosticTraceStore(directory: root)
        let run = DiagnosticRun(trigger: "test", subjects: ["formula"], store: store)
        defer {
            run.finish()
            try? FileManager.default.removeItem(at: root)
        }
        let runner = ScanStoreRuntimeProcessRunner(run: { request in
            let output: String
            switch request.arguments {
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                output = #"{"formulae":[],"casks":[]}"#
            case ["outdated"]: output = ""
            case ["outdated", "-g", "--json"]: output = "{}"
            default: throw CocoaError(.executableNotLoadable)
            }
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        })
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(formulae: [
            BrewOutdatedItem(name: "formula", installedVersions: ["1"], currentVersion: "2")
        ], casks: [])

        await UpdateDiagnostics.$current.withValue(run) {
            await harness.store.runUpdate(targetKeys: ["f:formula"])
        }

        let events = store.events(runID: run.id)
        XCTAssertEqual(harness.store.banner?.variant, .success)
        XCTAssertEqual(runner.requests.count, 4)
        XCTAssertTrue(events.contains { $0.event == "update.plannedItem" && $0.fields["targetVersion"] == "2" })
        XCTAssertTrue(events.contains { $0.event == "rescan.result" && $0.fields["confirmed"] == "true" })
        XCTAssertTrue(events.contains { $0.event == "update.itemVerdict" && $0.fields["verdict"] == "succeeded" })
        XCTAssertEqual(events.filter { $0.event == "trace.started" }.count, 1)
    }
}
