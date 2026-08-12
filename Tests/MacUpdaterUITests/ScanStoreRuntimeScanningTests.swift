import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

@MainActor
final class ScanStoreRuntimeScanningTests: XCTestCase {
    private enum StubError: Error {
        case unavailable
        case unexpected([String])
    }

    func testFullScanSuccessPublishesEverySourceAndPersistsTheResult() async throws {
        let formula = "scan-formula-\(UUID().uuidString)"
        let manualName = "Manual-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["update"]:
                return ProcessResult(exitCode: 0, stdout: "Already up-to-date", stderr: "")
            case ["list", "--cask", "-1"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                let json = #"{"formulae":[{"name":"\#(formula)","installed_versions":["1.0"],"current_version":"2.0"}],"casks":[]}"#
                return ProcessResult(exitCode: 0, stdout: json, stderr: "")
            case ["outdated"]:
                return ProcessResult(exitCode: 0, stdout: "123 Example App (1.0 -> 2.0)", stderr: "")
            case ["outdated", "-g", "--json"]:
                let json = #"{"scan-package":{"current":"1.0","wanted":"2.0","latest":"2.0"}}"#
                return ProcessResult(exitCode: 1, stdout: json, stderr: "")
            default:
                throw StubError.unexpected(request.arguments)
            }
        }
        let manual = ManualOutdatedApp(
            name: manualName,
            path: URL(fileURLWithPath: "/Applications/\(manualName).app"),
            installedVersion: "1.0",
            availableVersion: "2.0",
            source: .github(repo: "example/repo", selfUpdates: false)
        )
        let harness = makeScanStoreRuntimeHarness(
            runner: runner,
            manualScan: { _, casks in
                XCTAssertTrue(casks.isEmpty)
                return ([manual], 0)
            }
        )
        var activities: [UpdateActivity] = []
        var badgeCounts: [Int] = []
        harness.store.bind(ScanSinks(
            badgeChange: { badgeCounts.append($0) },
            activity: { activities.append($0) }
        ))

        await harness.store.runCheck()

        XCTAssertEqual(harness.store.status, .results)
        XCTAssertEqual(harness.store.progress, .finished)
        XCTAssertEqual(harness.store.brewOutdated?.formulae.map(\.name), [formula])
        XCTAssertEqual(harness.store.masOutdated.map(\.appStoreID), ["123"])
        XCTAssertEqual(harness.store.npmOutdated.map(\.name), ["scan-package"])
        XCTAssertEqual(harness.store.manualOutdated.map(\.name), [manualName])
        XCTAssertEqual(harness.store.failedSources, 0)
        XCTAssertEqual(harness.store.confirmedSourceKinds, [.formula, .cask, .appStore, .npm])
        XCTAssertTrue(harness.store.lastScanComplete)
        XCTAssertEqual(activities, [.scanning, .success])
        XCTAssertEqual(badgeCounts.last, 4)
        XCTAssertEqual(harness.reports.reports.last?.count, 4)
        XCTAssertEqual(harness.reports.reports.last?.failedChecks, 0)

        let data = try XCTUnwrap(harness.snapshots.data)
        let snapshot = try JSONDecoder().decode(ScanSnapshot.self, from: data)
        XCTAssertEqual(snapshot.brew?.formulae.map(\.name), [formula])
        XCTAssertEqual(snapshot.manual.map(\.name), [manualName])
        XCTAssertTrue(snapshot.isComplete)
    }

    func testFullScanTreatsMissingToolsAsUnavailableAndManualFailuresAsIncomplete() async {
        let runner = ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["update"], ["list", "--cask", "-1"],
                 ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                throw BrewServiceError.brewNotFound
            case ["outdated"]:
                throw MasServiceError.masNotFound
            case ["outdated", "-g", "--json"]:
                throw NpmServiceError.npmNotFound
            default:
                throw StubError.unexpected(request.arguments)
            }
        }
        let harness = makeScanStoreRuntimeHarness(
            runner: runner,
            manualScan: { _, _ in ([], 2) }
        )

        await harness.store.runCheck()

        XCTAssertEqual(harness.store.status, .results)
        XCTAssertFalse(harness.store.brewAvailable)
        XCTAssertEqual(harness.store.unavailableSources, 3)
        XCTAssertEqual(harness.store.failedSources, 2)
        XCTAssertFalse(harness.store.lastScanComplete)
        XCTAssertEqual(harness.store.sourceReports.brew?.outcome, .notInstalled)
        XCTAssertEqual(harness.store.sourceReports.mas?.outcome, .notInstalled)
        XCTAssertEqual(harness.store.sourceReports.npm?.outcome, .notInstalled)
        XCTAssertTrue(harness.store.sourceReports.manual?.didFail == true)
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertEqual(harness.reports.reports.last?.failedChecks, 2)
    }

    func testSourceErrorsKeepFoundManualUpdatesAndProducePartialFailure() async {
        let manual = ManualOutdatedApp(
            name: "Offline Manual",
            path: URL(fileURLWithPath: "/Applications/Offline Manual.app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle
        )
        let runner = ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["update"], ["list", "--cask", "-1"],
                 ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"],
                 ["outdated"], ["outdated", "-g", "--json"]:
                throw StubError.unavailable
            default:
                throw StubError.unexpected(request.arguments)
            }
        }
        let harness = makeScanStoreRuntimeHarness(
            runner: runner,
            manualScan: { _, _ in ([manual], 1) }
        )

        await harness.store.runCheck()

        XCTAssertEqual(harness.store.status, .results)
        XCTAssertEqual(harness.store.manualOutdated, [manual])
        XCTAssertEqual(harness.store.failedSources, 5)
        XCTAssertTrue(harness.store.sourceReports.brewMetadata?.didFail == true)
        XCTAssertTrue(harness.store.sourceReports.brew?.didFail == true)
        XCTAssertTrue(harness.store.sourceReports.mas?.didFail == true)
        XCTAssertTrue(harness.store.sourceReports.npm?.didFail == true)
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertEqual(harness.reports.reports.last?.count, 1)
    }

    func testCaskScanResolvesArtifactsDownloadsAndRollbackProtectionFromFakeBrewInfo() async {
        let token = "scan-cask-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                let json = #"{"formulae":[],"casks":[{"name":"\#(token)","installed_versions":["1"],"current_version":"2"}]}"#
                return ProcessResult(exitCode: 0, stdout: json, stderr: "")
            case ["outdated"], ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            case ["info", "--cask", "--json=v2", token]:
                let json = #"{"casks":[{"token":"\#(token)","homepage":"https://example.test","url":"https://example.test/app.dmg","sha256":"abc123","artifacts":[{"app":["Example.app"]}]}]}"#
                return ProcessResult(exitCode: 0, stdout: json, stderr: "")
            default:
                throw StubError.unexpected(request.arguments)
            }
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)

        await harness.store.runCheck(lightweight: true)

        XCTAssertEqual(harness.store.brewOutdated?.casks.map(\.name), [token])
        XCTAssertEqual(harness.store.caskIconPaths[token]?.lastPathComponent, "Example.app")
        XCTAssertEqual(harness.store.caskDownloads[token]?.sha256, "abc123")
        XCTAssertEqual(harness.store.caskProfiles[token]?.appArtifacts, ["Example.app"])
        XCTAssertEqual(harness.store.caskProtection[token], .protected)
        XCTAssertTrue(harness.store.caskSizes.isEmpty)
    }

    func testStartAndCancelCheckLeavesTheStoreInCancelledState() async {
        let runner = ScanStoreRuntimeProcessRunner { _ in
            try await Task.sleep(for: .seconds(30))
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)

        harness.store.startCheck()
        await Task.yield()
        harness.store.cancelScan()
        while harness.store.scanTask != nil {
            await Task.yield()
        }

        XCTAssertEqual(harness.store.status, .ready)
        XCTAssertEqual(harness.store.progress, .cancelled(at: .brew))
    }
}
