import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

@MainActor
final class ScanStoreRuntimeUpdateGapTests: XCTestCase {
    private enum StubError: Error {
        case processFailed
        case unexpected([String])
    }

    func testCaskUpdateRetriesInterruptedStagingWithForceAndConfirmsTheResult() async {
        let token = "retry-cask-\(UUID().uuidString)"
        let operationBaseline = Set(UpdateOperationStore.shared.operations().map(\.id))
        defer { removeScanStoreRuntimeOperations(createdAfter: operationBaseline) }
        let gateDefaults = ScanStoreRuntimeDownloadGateDefaults()
        defer { gateDefaults.restore() }

        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["info", "--cask", "--json=v2", token]:
                    return ProcessResult(exitCode: 0, stdout: #"{"casks":[]}"#, stderr: "")
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
                guard request.arguments.starts(with: ["upgrade", "--cask"]) else {
                    return .failure(StubError.unexpected(request.arguments))
                }
                if request.arguments.contains("--force") {
                    return .success([
                        .stdout("Successfully upgraded \(token)\n"),
                        .finished(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
                    ])
                }
                return .success([
                    .stderr(
                        "Error: \(token): It seems there is already an App at '/Applications/Retry.app'\n"
                    ),
                    .finished(ProcessResult(exitCode: 1, stdout: "", stderr: "")),
                ])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [],
            casks: [BrewOutdatedItem(
                name: token,
                installedVersions: ["1"],
                currentVersion: "2"
            )]
        )
        harness.store.caskDownloads[token] = CaskDownloadInfo(token: token, url: nil, sha256: nil)
        let key = UpdatePlanner.key(name: token, kind: .cask)

        await harness.store.runUpdate(targetKeys: [key])

        XCTAssertFalse(harness.store.updating)
        XCTAssertTrue(harness.store.allItems.isEmpty)
        XCTAssertEqual(harness.store.banner?.variant, .success)
        XCTAssertTrue(runner.requests.contains {
            $0.arguments == ["upgrade", "--cask", "--force", "--", token]
        })
        XCTAssertTrue(harness.store.brewLog.contains { $0.contains("--force") })
    }

    func testCaskPreparationBlocksBeforeMutationWhenRequiredResourcesCannotFit() async {
        let token = "oversized-cask-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            guard request.arguments == ["info", "--cask", "--json=v2", token] else {
                throw StubError.unexpected(request.arguments)
            }
            return ProcessResult(exitCode: 0, stdout: #"{"casks":[]}"#, stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [],
            casks: [BrewOutdatedItem(
                name: token,
                installedVersions: ["1"],
                currentVersion: "2"
            )]
        )
        harness.store.caskSizes[token] = .known(bytes: Int64.max)
        let key = UpdatePlanner.key(name: token, kind: .cask)

        await harness.store.runUpdate(targetKeys: [key])

        XCTAssertFalse(harness.store.updating)
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertTrue(harness.store.brewLog.contains { $0.contains("odroczona") })
        XCTAssertFalse(runner.requests.contains { $0.arguments.first == "upgrade" })
    }

    func testFailureReportingDistinguishesAppManagementFromSudoPassword() async {
        let permission = makeFormulaFailureHarness(
            output: "ditto: /Applications/Denied.app: Operation not permitted\nError: denied: install failed\n"
        )
        await permission.harness.store.runUpdate(targetKeys: [permission.key])

        XCTAssertEqual(permission.harness.store.banner?.action, .openAppManagementSettings)
        XCTAssertEqual(permission.harness.store.banner?.variant, .danger)

        let sudo = makeFormulaFailureHarness(
            output: "sudo: a password is required\nError: sudo-failure: install failed\n"
        )
        await sudo.harness.store.runUpdate(targetKeys: [sudo.key])

        XCTAssertEqual(sudo.harness.store.banner?.action, .openSettings)
        XCTAssertEqual(sudo.harness.store.banner?.variant, .danger)
    }

    func testManualAdoptionReportsContentionThenSnapshotFailureWithoutInstalling() async {
        let token = "adoption-cask-\(UUID().uuidString)"
        let operationBaseline = Set(UpdateOperationStore.shared.operations().map(\.id))
        defer { removeScanStoreRuntimeOperations(createdAfter: operationBaseline) }
        let gateDefaults = ScanStoreRuntimeDownloadGateDefaults()
        defer { gateDefaults.restore() }
        let runner = ScanStoreRuntimeProcessRunner { request in
            guard request.arguments == ["info", "--cask", "--json=v2", token] else {
                throw StubError.unexpected(request.arguments)
            }
            return ProcessResult(exitCode: 0, stdout: #"{"casks":[]}"#, stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)

        XCTAssertTrue(UpgradeMutex.shared.acquire())
        defer {
            if UpgradeMutex.shared.isBusy {
                UpgradeMutex.shared.release()
            }
        }
        await harness.store.installManual(token: token)
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertTrue(runner.requests.isEmpty)
        UpgradeMutex.shared.release()

        let missingApp = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).app")
        harness.store.manualOutdated = [ManualOutdatedApp(
            name: "Missing App",
            path: missingApp,
            installedVersion: "1",
            availableVersion: "2",
            source: .cask(token: token),
            bundleIdentifier: "example.missing"
        )]
        await harness.store.installManual(token: token)

        XCTAssertNil(harness.store.manualBusy)
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertTrue(runner.requests.contains {
            $0.arguments == ["info", "--cask", "--json=v2", token]
        })
        XCTAssertFalse(runner.requests.contains { $0.arguments.first == "install" })
    }

    func testUpdateHandlesMutexContentionAndAThrownBrewStream() async {
        let token = "throwing-formula-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    let json = #"{"formulae":[{"name":"\#(token)","installed_versions":["1"],"current_version":"2"}],"casks":[]}"#
                    return ProcessResult(exitCode: 0, stdout: json, stderr: "")
                case ["outdated"]:
                    return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                case ["outdated", "-g", "--json"]:
                    return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
                default:
                    throw StubError.unexpected(request.arguments)
                }
            },
            events: { _ in .failure(StubError.processFailed) }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(
                name: token,
                installedVersions: ["1"],
                currentVersion: "2"
            )],
            casks: []
        )
        let key = UpdatePlanner.key(name: token, kind: .formula)

        XCTAssertTrue(UpgradeMutex.shared.acquire())
        await harness.store.runUpdate(targetKeys: [key])
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertTrue(runner.requests.isEmpty)
        UpgradeMutex.shared.release()

        await harness.store.runUpdate(targetKeys: [key])

        XCTAssertFalse(harness.store.updating)
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertTrue(harness.store.brewLog.contains { $0.hasPrefix("error:") })
    }

    private func makeFormulaFailureHarness(
        output: String
    ) -> (harness: ScanStoreRuntimeHarness, key: String) {
        let token = "formula-failure-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    let json = #"{"formulae":[{"name":"\#(token)","installed_versions":["1"],"current_version":"2"}],"casks":[]}"#
                    return ProcessResult(exitCode: 0, stdout: json, stderr: "")
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
                    .stderr(output),
                    .finished(ProcessResult(exitCode: 1, stdout: "", stderr: "")),
                ])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(
                name: token,
                installedVersions: ["1"],
                currentVersion: "2"
            )],
            casks: []
        )
        return (harness, UpdatePlanner.key(name: token, kind: .formula))
    }
}
