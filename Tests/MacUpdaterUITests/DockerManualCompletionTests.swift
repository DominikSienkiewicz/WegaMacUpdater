import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

@MainActor
final class DockerManualCompletionTests: XCTestCase {
    func testVerifiedHomebrewInstallationClearsDockerRowAndOffersExplicitRestart() {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            XCTFail("Reporting an installation must not start a process")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let store = makeScanStoreRuntimeHarness(runner: runner).store
        let path = URL(fileURLWithPath: "/TestApplications/Docker.app")
        store.brewOutdated = .init(formulae: [], casks: [
            .init(name: "docker-desktop", installedVersions: ["4.50"], currentVersion: "4.51")
        ])
        store.caskIconPaths = ["docker-desktop": path]
        store.manualOutdated = [ManualOutdatedApp(
            name: "Docker", path: path, installedVersion: "4.50", availableVersion: "4.51",
            source: .sparkle, bundleIdentifier: "com.docker.docker", caskPolicyToken: "docker-desktop"
        )]

        store.reportManualInstallSuccess(token: "docker-desktop", appURL: path)

        XCTAssertTrue(store.visibleManual.isEmpty, "Verified installation must close the managed and cached vendor rows")
        XCTAssertTrue(store.allItems.isEmpty)
        XCTAssertEqual(store.restartCandidates.count, 1)
        XCTAssertEqual(Array(store.restartDockerBundleURLs.values), [path])
        XCTAssertEqual(store.banner?.message, tr("Pakiety zainstalowane. Gotowość silnika Docker nie była sprawdzana."))
        XCTAssertTrue(runner.requests.isEmpty)
    }
}
