import Combine
import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

/// The launch sequence, as the user meets it: a list restored from disk that has to look like
/// the result it is, and a scan that corrects it without taking the window away from it.
///
/// The bug these pin: a cold launch painted lettered placeholders where a finished scan had
/// painted app icons, and the numbers beside them stayed last time's until the user thought to
/// press refresh — so the first screen of the app read as a mock-up of itself.
@MainActor
final class QuietLaunchRefreshTests: XCTestCase {
    private enum StubError: Error {
        case unexpected([String])
    }

    /// A runner that answers every command a full scan asks, finding nothing outdated.
    private func idleRunner() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["update"]:
                return ProcessResult(exitCode: 0, stdout: "Already up-to-date", stderr: "")
            case ["list", "--cask", "-1"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
            case ["outdated"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            default:
                throw StubError.unexpected(request.arguments)
            }
        }
    }

    private func snapshot(
        scannedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        caskAppPaths: [String: URL]
    ) -> ScanSnapshot {
        ScanSnapshot(
            scannedAt: scannedAt,
            brew: BrewOutdated(
                formulae: [],
                casks: [BrewOutdatedItem(name: "iterm2", installedVersions: ["3.4"], currentVersion: "3.5")]
            ),
            mas: [],
            npm: [],
            manual: [],
            caskAppPaths: caskAppPaths,
            sources: ScanSourceReports(
                brew: ScanSourceReport(outcome: .succeeded),
                mas: ScanSourceReport(outcome: .succeeded),
                npm: ScanSourceReport(outcome: .succeeded),
                manual: ScanSourceReport(outcome: .succeeded)
            )
        )
    }

    // MARK: Icons

    /// Restoring a scan has to restore what it looked like, not only what it found.
    func testRestoreBringsBackTheCaskIcons() throws {
        let harness = makeScanStoreRuntimeHarness(runner: idleRunner())
        let path = URL(fileURLWithPath: "/Applications/iTerm.app")
        try ScanResultStore(io: harness.snapshots).save(snapshot(caskAppPaths: ["iterm2": path]))

        harness.store.restoreLastScan()

        XCTAssertEqual(harness.store.caskIconPaths, ["iterm2": path],
                       "a restored row must draw its icon, not a letter tile")
    }

    /// An icon is a claim that the app is on this machine. A cask uninstalled since the scan
    /// has to come back as a letter tile rather than as the icon of a bundle that is gone.
    func testRestoreDropsIconsWhoseBundleIsGone() throws {
        let present = URL(fileURLWithPath: "/Applications/iTerm.app")
        let removed = URL(fileURLWithPath: "/Applications/Gone.app")
        let harness = makeScanStoreRuntimeHarness(
            runner: idleRunner(),
            bundleExists: { $0 == present }
        )
        try ScanResultStore(io: harness.snapshots).save(
            snapshot(caskAppPaths: ["iterm2": present, "gone": removed])
        )

        harness.store.restoreLastScan()

        XCTAssertEqual(harness.store.caskIconPaths, ["iterm2": present])
    }

    /// The other half of the round trip: a finished scan has to hand its map to the file, or
    /// the next launch is back to letter tiles however well the restore reads.
    func testAFinishedScanPersistsTheIconsItResolved() async throws {
        let harness = makeScanStoreRuntimeHarness(runner: idleRunner())
        let iterm = URL(fileURLWithPath: "/Applications/iTerm.app")
        harness.store.brewOutdated = BrewOutdated(
            formulae: [],
            casks: [BrewOutdatedItem(name: "iterm2", installedVersions: ["3.4"], currentVersion: "3.5")]
        )
        harness.store.caskIconPaths = ["iterm2": iterm]
        harness.store.lastCheck = Date(timeIntervalSince1970: 1_700_000_000)

        harness.store.persistLastScan()

        let data = try XCTUnwrap(harness.snapshots.data)
        let written = try JSONDecoder().decode(ScanSnapshot.self, from: data)
        XCTAssertEqual(written.caskAppPaths, ["iterm2": iterm])
    }

    /// A scan never empties `caskIconPaths`, so a cask updated today would keep its path in the
    /// file for every scan after it — the map has to be cut down to what the result it belongs
    /// to actually lists, or the snapshot grows a path per cask ever updated on this machine.
    func testThePersistedIconMapCoversOnlyTheCasksTheResultLists() async throws {
        let harness = makeScanStoreRuntimeHarness(runner: idleRunner())
        harness.store.brewOutdated = BrewOutdated(
            formulae: [],
            casks: [BrewOutdatedItem(name: "iterm2", installedVersions: ["3.4"], currentVersion: "3.5")]
        )
        harness.store.caskIconPaths = [
            "iterm2": URL(fileURLWithPath: "/Applications/iTerm.app"),
            "updated-last-week": URL(fileURLWithPath: "/Applications/Old.app")
        ]
        harness.store.lastCheck = Date(timeIntervalSince1970: 1_700_000_000)

        harness.store.persistLastScan()

        let data = try XCTUnwrap(harness.snapshots.data)
        let written = try JSONDecoder().decode(ScanSnapshot.self, from: data)
        XCTAssertEqual(Set(written.caskAppPaths.keys), ["iterm2"])
    }

    // MARK: The quiet scan

    /// The point of the whole change: a quiet scan never hands the window to the scanning
    /// screen. Asserted over every value `status` published during the run, because the flash
    /// this prevents is a transition, not an end state — checking `status` afterwards would
    /// pass just as happily against the bug.
    func testAQuietScanNeverReplacesTheResultsScreen() async throws {
        let harness = makeScanStoreRuntimeHarness(runner: idleRunner())
        harness.store.lastCheck = Date(timeIntervalSince1970: 1_700_000_000)
        harness.store.status = .results

        var published: [UpdateStatus] = []
        let subscription = harness.store.$status.sink { published.append($0) }
        defer { subscription.cancel() }

        await harness.store.runCheck(quiet: true)

        XCTAssertFalse(published.contains(.checking),
                       "the restored list must stay on screen for the whole quiet scan")
        XCTAssertEqual(harness.store.status, .results)
        XCTAssertFalse(harness.store.isRefreshing, "the flag must not outlive the scan")
    }

    /// The contrast, so the assertion above cannot pass by the scan not running at all: a scan
    /// the user starts still takes the window.
    func testAnOrdinaryScanStillTakesTheWindow() async throws {
        let harness = makeScanStoreRuntimeHarness(runner: idleRunner())

        var published: [UpdateStatus] = []
        let subscription = harness.store.$status.sink { published.append($0) }
        defer { subscription.cancel() }

        await harness.store.runCheck()

        XCTAssertTrue(published.contains(.checking))
        XCTAssertEqual(harness.store.status, .results)
    }

    // MARK: The launch latch

    /// `UpdateView.onAppear` runs again on every tab switch and on every language re-key. The
    /// refresh is a launch event, not an appearance event.
    func testTheLaunchRefreshRunsOnlyOnce() async throws {
        let runner = idleRunner()
        let harness = makeScanStoreRuntimeHarness(runner: runner)
        try ScanResultStore(io: harness.snapshots).save(snapshot(caskAppPaths: [:]))
        harness.store.restoreLastScan()

        harness.store.startLaunchRefresh()
        await harness.store.scanTask?.value
        let afterFirst = runner.requests.count
        XCTAssertGreaterThan(afterFirst, 0, "the first appearance must actually refresh")

        harness.store.startLaunchRefresh()
        await harness.store.scanTask?.value

        XCTAssertEqual(runner.requests.count, afterFirst,
                       "a second appearance must not start another scan")
    }

    /// With a list on screen the refresh has something to protect; with nothing restored there
    /// is no list to flash away, so the ordinary scanning screen is the honest thing to show.
    func testTheLaunchRefreshIsQuietOnlyWhenThereIsAResultToProtect() async throws {
        let restored = makeScanStoreRuntimeHarness(runner: idleRunner())
        try ScanResultStore(io: restored.snapshots).save(snapshot(caskAppPaths: [:]))
        restored.store.restoreLastScan()

        var restoredStatuses: [UpdateStatus] = []
        let restoredSubscription = restored.store.$status.sink { restoredStatuses.append($0) }
        defer { restoredSubscription.cancel() }
        restored.store.startLaunchRefresh()
        await restored.store.scanTask?.value

        XCTAssertFalse(restoredStatuses.contains(.checking))

        let cold = makeScanStoreRuntimeHarness(runner: idleRunner())
        cold.store.restoreLastScan()
        XCTAssertEqual(cold.store.status, .ready, "nothing on disk, nothing to restore")

        var coldStatuses: [UpdateStatus] = []
        let coldSubscription = cold.store.$status.sink { coldStatuses.append($0) }
        defer { coldSubscription.cancel() }
        cold.store.startLaunchRefresh()
        await cold.store.scanTask?.value

        XCTAssertTrue(coldStatuses.contains(.checking),
                      "a first launch has no list to protect — show the scan")
    }
}
