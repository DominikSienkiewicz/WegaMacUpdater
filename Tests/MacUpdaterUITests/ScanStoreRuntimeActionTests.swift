import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

@MainActor
final class ScanStoreRuntimeActionTests: XCTestCase {
    private enum StubError: Error {
        case unexpected([String])
    }

    func testStaleCaskCleanupKeepsFailuresAndRemovesOnlySuccessfulTokens() async {
        let removed = "removed-\(UUID().uuidString)"
        let failed = "failed-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            guard request.arguments.starts(with: ["uninstall", "--cask", "--force", "--"]),
                  let token = request.arguments.last else {
                throw StubError.unexpected(request.arguments)
            }
            if token == removed {
                return ProcessResult(exitCode: 0, stdout: "Uninstalled", stderr: "")
            }
            return ProcessResult(exitCode: 1, stdout: "", stderr: "still installed")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.staleCasks = [removed, failed]

        await harness.store.cleanUpStaleCasks()

        XCTAssertFalse(harness.store.cleaningStaleCasks)
        XCTAssertEqual(harness.store.staleCasks, [failed])
        XCTAssertEqual(harness.store.banner?.variant, .danger)
        XCTAssertEqual(runner.requests.filter { $0.arguments.first == "uninstall" }.count, 2)

        harness.store.dismissStaleCasks()
        XCTAssertTrue(harness.store.staleCasks.isEmpty)
    }

    func testManualInstallWithoutAMatchingAppStopsBeforeAnyProcessOrFilesystemMutation() async {
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        var activities: [UpdateActivity] = []
        harness.store.bind(ScanSinks(activity: { activities.append($0) }))

        await harness.store.installManual(token: "missing-cask")

        XCTAssertNil(harness.store.manualBusy)
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertEqual(activities, [.scanning, .error])
        XCTAssertEqual(harness.store.banner?.variant, .danger)
    }

    func testRollbackMetadataResolutionUsesFreshBrewInfoAndClearsStateWhenNoCasksRemain() async {
        let appToken = "app-cask-\(UUID().uuidString)"
        let pkgToken = "pkg-cask-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            guard request.arguments.starts(with: ["info", "--cask", "--json=v2"]) else {
                throw StubError.unexpected(request.arguments)
            }
            let requested = Set(request.arguments.dropFirst(3))
            var casks: [String] = []
            if requested.contains(appToken) {
                casks.append(#"{"token":"\#(appToken)","artifacts":[{"app":["Fresh.app"]}]}"#)
            }
            if requested.contains(pkgToken) {
                casks.append(#"{"token":"\#(pkgToken)","artifacts":[{"pkg":["Installer.pkg"]}]}"#)
            }
            return ProcessResult(
                exitCode: 0,
                stdout: "{\"casks\":[\(casks.joined(separator: ","))]}",
                stderr: ""
            )
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.caskIconPaths = [appToken: URL(fileURLWithPath: "/Applications/Stale.app")]

        let paths = await harness.store.resolveCaskAppPaths([appToken])

        XCTAssertEqual(paths[appToken]?.lastPathComponent, "Fresh.app")

        harness.store.brewOutdated = BrewOutdated(
            formulae: [],
            casks: [
                BrewOutdatedItem(name: appToken, installedVersions: ["1"], currentVersion: "2"),
                BrewOutdatedItem(name: pkgToken, installedVersions: ["1"], currentVersion: "2"),
            ]
        )
        harness.store.caskSizes = [appToken: .known(bytes: 123)]
        await harness.store.resolveRollbackProtection()

        XCTAssertEqual(harness.store.caskProtection[appToken], .protected)
        XCTAssertEqual(harness.store.caskProtection[pkgToken], .unprotected(.noAppBundle))
        XCTAssertEqual(harness.store.caskProfiles[appToken]?.appArtifacts, ["Fresh.app"])
        XCTAssertTrue(harness.store.caskSizes.isEmpty)

        harness.store.brewOutdated = BrewOutdated(formulae: [], casks: [])
        await harness.store.resolveRollbackProtection()
        XCTAssertTrue(harness.store.caskProtection.isEmpty)
        XCTAssertTrue(harness.store.caskProfiles.isEmpty)
    }

    func testPlanPreviewUsesTheStoreItemsAndSkipsMissingDownloadURLsWithoutNetworking() async {
        let formula = "plan-formula-\(UUID().uuidString)"
        let cask = "plan-cask-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")],
            casks: [BrewOutdatedItem(name: cask, installedVersions: ["1"], currentVersion: "2")]
        )
        harness.store.caskDownloads[cask] = CaskDownloadInfo(token: cask, url: nil, sha256: nil)
        let keys = Set(harness.store.allItems.map(\.key))

        let commands = harness.store.plannedCommands(targetKeys: keys)
        XCTAssertEqual(commands.map(\.executable), ["brew", "brew"])
        XCTAssertEqual(harness.store.plannedCaskTokens(targetKeys: keys), [cask])

        await harness.store.probeDownloadSizes(targetKeys: keys)

        XCTAssertFalse(harness.store.probingSizes)
        XCTAssertNil(harness.store.caskSizes[cask])
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testUndoRefreshAndBusyGuardUseInjectedStateWithoutTouchingTheOperationDirectory() async {
        let undoable = UndoableUpdate(
            operationID: UUID(),
            token: "undo-cask",
            appPath: "/Applications/Undo.app",
            restoredVersion: "1.0",
            updatedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(
            runner: runner,
            undoableUpdates: { [undoable] }
        )

        harness.store.refreshUndoableUpdates()
        XCTAssertEqual(harness.store.undoableUpdates, [undoable])

        harness.store.undoBusy = "another-cask"
        await harness.store.undoUpdate(undoable)

        XCTAssertEqual(harness.store.undoBusy, "another-cask")
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testStoreDerivedStateSinksInspectorAndBannerQueueExecuteAtRuntime() throws {
        let formula = "state-formula-\(UUID().uuidString)"
        let manual = ManualOutdatedApp(
            name: "Security App",
            path: URL(fileURLWithPath: "/Applications/Security App.app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle,
            releaseNotes: "Critical security fix",
            bundleIdentifier: "example.security"
        )
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")],
            casks: []
        )
        harness.store.manualOutdated = [manual]
        harness.store.lastCheck = Date(timeIntervalSince1970: 1_700_000_000)
        harness.store.status = .results
        harness.store.inspectedKey = "m:" + manual.path.path
        var badge = 0
        var errors = -1
        var footerSecurity = -1
        var categoryCounts = (-1, -1)
        var state: WegaState?
        var activity: UpdateActivity?
        harness.store.bind(ScanSinks(
            wegaState: { state = $0 },
            badgeChange: { badge = $0 },
            errorCount: { errors = $0 },
            activity: { activity = $0 },
            footerInfo: { _, security in footerSecurity = security },
            categoryCounts: { categoryCounts = ($0, $1) }
        ))

        harness.store.emitWegaState(WegaState(pose: .sniff, line: "testing"))
        harness.store.emitActivitySignal(.scanning)
        harness.store.emitCounts()
        harness.store.replayLastScan()

        XCTAssertEqual(state, WegaState(pose: .sniff, line: "testing"))
        XCTAssertEqual(activity, .scanning)
        XCTAssertEqual(badge, 2)
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(footerSecurity, 1)
        XCTAssertEqual(categoryCounts.0, 1)
        XCTAssertEqual(categoryCounts.1, 1)
        if case .manual(let inspected) = try XCTUnwrap(harness.store.inspectedUpdate) {
            XCTAssertEqual(inspected, manual)
        } else {
            XCTFail("expected the manual inspector item")
        }
        XCTAssertNotNil(harness.store.freshness(now: Date(timeIntervalSince1970: 1_700_000_100)))

        harness.store.toggleAll(filter: .all)
        XCTAssertEqual(harness.store.selected, [UpdatePlanner.key(name: formula, kind: .formula)])
        harness.store.restrictSelection(to: .apps)
        XCTAssertTrue(harness.store.selected.isEmpty)

        let transient = BannerData(variant: .success, title: "done", message: "done")
        let sticky = BannerData(variant: .danger, title: "important", message: "important")
        harness.store.showBanner(transient)
        harness.store.showStickyBanner(sticky)
        XCTAssertEqual(harness.store.banner, sticky)
        harness.store.dismissBanner()
        XCTAssertEqual(harness.store.banner, transient)
        harness.store.dismissBanner()
        XCTAssertNil(harness.store.banner)

        harness.store.applyScanSourceReports(ScanSourceReports(
            brew: ScanSourceReport(outcome: .failed("offline"), error: "offline")
        ))
        XCTAssertFalse(harness.store.lastScanComplete)
        harness.store.persistLastScan()
        XCTAssertNotNil(harness.snapshots.data)
    }
}
