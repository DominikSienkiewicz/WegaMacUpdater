import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

@MainActor
final class ScanStoreRuntimeUpdatingTests: XCTestCase {
    private enum StubError: Error {
        case masUpgradeFailed
        case npmUpgradeFailed
        case unexpected([String])
    }

    func testSuccessfulFormulaMasAndNpmRunExecutesThenConfirmsEveryItemByRescan() async {
        let formula = "update-formula-\(UUID().uuidString)"
        let package = "update-package-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["upgrade", "123"]:
                    return ProcessResult(exitCode: 0, stdout: "Updated Example App", stderr: "")
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
                case ["outdated"]:
                    return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                case ["outdated", "-g", "--json"]:
                    return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
                default:
                    throw StubError.unexpected(request.arguments)
                }
            },
            events: { request in
                switch request.arguments.first {
                case "upgrade":
                    return .success([
                        .stdout("Upgrading \(formula)\n"),
                        .finished(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
                    ])
                case "install":
                    return .success([
                        .stderr("npm notice installed \(package)\n"),
                        .finished(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
                    ])
                default:
                    return .failure(StubError.unexpected(request.arguments))
                }
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")],
            casks: []
        )
        harness.store.masOutdated = [MasOutdatedApp(
            appStoreID: "123",
            name: "Example App",
            installedVersion: "1",
            currentVersion: "2"
        )]
        harness.store.npmOutdated = [NpmGlobalOutdated(
            name: package,
            installedVersion: "1",
            latestVersion: "2"
        )]
        let keys = Set(harness.store.allItems.map(\.key))
        harness.store.selected = keys
        var activities: [UpdateActivity] = []
        harness.store.bind(ScanSinks(activity: { activities.append($0) }))

        await harness.store.runUpdate(targetKeys: keys)

        XCTAssertFalse(harness.store.updating)
        XCTAssertTrue(harness.store.selected.isEmpty)
        XCTAssertTrue(harness.store.allItems.isEmpty)
        XCTAssertEqual(harness.store.banner?.variant, .success)
        XCTAssertEqual(harness.store.confirmedSourceKinds, [.formula, .cask, .appStore, .npm])
        XCTAssertEqual(activities, [.scanning, .success])
        XCTAssertTrue(harness.store.brewLog.contains { $0.contains("Upgrading \(formula)") })
        XCTAssertTrue(harness.store.brewLog.contains { $0.contains("Updated Example App") })
        XCTAssertTrue(harness.store.brewLog.contains { $0.contains("npm notice installed") })
        XCTAssertEqual(harness.reports.reports.last?.count, 0)
        XCTAssertTrue(harness.store.undoableUpdates.isEmpty)
    }

    func testFailedFormulaStaysVisibleAndProducesAnIncompleteBannerWithDiagnostics() async {
        let formula = "failed-formula-\(UUID().uuidString)"
        let outdatedJSON = #"{"formulae":[{"name":"\#(formula)","installed_versions":["1"],"current_version":"2"}],"casks":[]}"#
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    return ProcessResult(exitCode: 0, stdout: outdatedJSON, stderr: "")
                case ["outdated"]:
                    return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                case ["outdated", "-g", "--json"]:
                    return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
                default:
                    throw StubError.unexpected(request.arguments)
                }
            },
            events: { _ in
                .success([
                    .stderr("Error: \(formula): archive missing\nsource app was not there\n"),
                    .finished(ProcessResult(exitCode: 1, stdout: "", stderr: "")),
                ])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")],
            casks: []
        )
        let key = UpdatePlanner.key(name: formula, kind: .formula)

        await harness.store.runUpdate(targetKeys: [key])

        XCTAssertFalse(harness.store.updating)
        XCTAssertEqual(harness.store.allItems.map(\.name), [formula])
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertTrue(harness.store.banner?.message.contains(formula) == true)
        XCTAssertTrue(harness.store.brewLog.contains { $0.contains("archive missing") })
    }

    func testNpmStreamAndMasFailuresAreRecordedWithoutEscapingTheUpdateRun() async {
        let package = "failed-package-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["upgrade", "321"]:
                    throw StubError.masUpgradeFailed
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
                case ["outdated"]:
                    return ProcessResult(exitCode: 0, stdout: "321 Broken App (1 -> 2)", stderr: "")
                case ["outdated", "-g", "--json"]:
                    let json = #"{"\#(package)":{"current":"1","wanted":"2","latest":"2"}}"#
                    return ProcessResult(exitCode: 1, stdout: json, stderr: "")
                default:
                    throw StubError.unexpected(request.arguments)
                }
            },
            events: { _ in .failure(StubError.npmUpgradeFailed) }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.masOutdated = [MasOutdatedApp(
            appStoreID: "321",
            name: "Broken App",
            installedVersion: "1",
            currentVersion: "2"
        )]
        harness.store.npmOutdated = [NpmGlobalOutdated(
            name: package,
            installedVersion: "1",
            latestVersion: "2"
        )]
        let keys = Set(harness.store.allItems.map(\.key))

        await harness.store.runUpdate(targetKeys: keys)

        XCTAssertFalse(harness.store.updating)
        XCTAssertEqual(Set(harness.store.allItems.map(\.name)), ["Broken App", package])
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertEqual(harness.store.brewLog.filter { $0.hasPrefix("error:") }.count, 2)
    }

    func testEmptyUpdateRequestIsANoOp() async {
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)

        await harness.store.runUpdate(targetKeys: [])

        XCTAssertFalse(harness.store.updating)
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertNil(harness.store.banner)
    }
}
