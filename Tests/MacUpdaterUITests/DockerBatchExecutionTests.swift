import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

@MainActor
final class DockerBatchExecutionTests: XCTestCase {
    func testStaleDockerOnlySelectionDoesNotExecuteOrReportAnUpdate() async {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "fake process")
        }
        let store = makeScanStoreRuntimeHarness(runner: runner).store
        store.brewOutdated = .init(formulae: [], casks: [
            .init(name: "docker-desktop", installedVersions: ["4.50"], currentVersion: "4.51")
        ])

        await store.runUpdate(targetKeys: ["c:docker-desktop"])

        XCTAssertTrue(runner.requests.isEmpty, "A stale Docker selection must not reach a package manager")
        XCTAssertNil(store.banner, "An excluded selection must not be reported as a successful update")
        XCTAssertFalse(store.updating)
    }
}
