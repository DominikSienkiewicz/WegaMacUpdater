import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-05 — the window used to take the menu-bar agent's result once per process, so a click
/// on "new updates" opened a list that did not have them.
@Suite("Background result adoption") @MainActor
struct BackgroundResultAdoptionTests {
    private func makeStore() -> ScanStore {
        let runner = ScanStoreRuntimeProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "{}", stderr: "") }
        return makeScanStoreRuntimeHarness(runner: runner).store
    }

    private func result(at date: Date) -> MenuBarScanResult {
        MenuBarScanResult(
            brew: BrewOutdated(formulae: [], casks: [BrewOutdatedItem(name: "adopt-cask", installedVersions: ["1"], currentVersion: "2")]),
            mas: [], npm: [], manualApps: [], failedChecks: 0, scannedAt: date, total: 1
        )
    }

    @Test func aNewerBackgroundResultReplacesTheWindowList() {
        let store = makeStore()
        let anHourAgo = Date.now.addingTimeInterval(-3600)
        store.lastCheck = anHourAgo
        store.status = .results
        let fresh = result(at: .now)
        let adopted = store.adoptBackgroundResultIfNewer(fresh)
        #expect(adopted && store.lastCheck == fresh.scannedAt)
        #expect(store.brewOutdated?.casks.map(\.name) == ["adopt-cask"])
    }

    @Test func anOlderResultChangesNothing() {
        let store = makeStore()
        let recent = Date.now
        store.lastCheck = recent
        store.status = .results
        let adopted = store.adoptBackgroundResultIfNewer(result(at: recent.addingTimeInterval(-3600)))
        #expect(!adopted)
        #expect(store.lastCheck == recent)
        #expect(store.brewOutdated == nil)
    }

    @Test func nothingIsAdoptedWhileUpdatingOrChecking() {
        let store = makeStore()
        store.lastCheck = Date.now.addingTimeInterval(-3600)
        store.status = .results
        store.updating = true
        #expect(!store.adoptBackgroundResultIfNewer(result(at: .now)))
        store.updating = false
        store.status = .checking
        #expect(!store.adoptBackgroundResultIfNewer(result(at: .now)))
        #expect(store.brewOutdated == nil)
    }

    /// M11a — a launch refresh keeps `status` at `.results` while it scans underneath the list,
    /// so the status guard alone let a background result replace what the scan is about to.
    @Test func nothingIsAdoptedWhileARefreshScansUnderTheList() {
        let store = makeStore()
        store.lastCheck = Date.now.addingTimeInterval(-3600)
        store.status = .results
        store.setRefreshing(true)
        defer { store.setRefreshing(false) }
        #expect(!store.adoptBackgroundResultIfNewer(result(at: .now)))
        #expect(store.brewOutdated == nil)
    }

    /// The window was closed, a background round arrived, the window reopens: the one-shot
    /// restore has already run, so only the adopt call can bring the new list in.
    @Test func aResultThatArrivedAfterTheRestoreStillReachesTheList() {
        let store = makeStore()
        store.restoreLastScan()
        store.lastCheck = Date.now.addingTimeInterval(-3600)
        store.status = .results
        let fresh = result(at: .now)
        #expect(store.adoptBackgroundResultIfNewer(fresh))
        #expect(store.brewOutdated?.casks.map(\.name) == ["adopt-cask"])
    }

    @Test func reopeningTheWindowAdoptsTheCurrentResultAfterTheRestore() throws {
        let source = try String(contentsOfFile: Self.path("Sources/MacUpdater/UpdateView.swift"), encoding: .utf8)
        let restore = try #require(source.range(of: "scan.restoreLastScan()"))
        let adopt = try #require(source.range(of: "scan.adoptBackgroundResultIfNewer(background)"),
                                 "UXP-05: a reopened window never adopts the result that arrived while it was closed")
        #expect(restore.lowerBound < adopt.lowerBound)
        #expect(source.contains("MenuBarAgent.shared.lastResult"))
    }

    @Test func aSwitchedOffNotificationChoiceIsHonouredWhenPosting() throws {
        let source = try String(contentsOfFile: Self.path("Sources/MacUpdater/MenuBarAgent.swift"), encoding: .utf8)
        let post = try #require(source.range(of: "private func postNotification(count: Int"))
        let guardLine = try #require(source.range(of: "inAppAnswer != .declined"))
        #expect(post.lowerBound < guardLine.lowerBound)
    }

    /// M4 — the notification names the apps that are new since the previous round first.
    @Test func theNotificationNamesTheNewAppsFirst() throws {
        let source = try String(contentsOfFile: Self.path("Sources/MacUpdater/MenuBarAgent.swift"), encoding: .utf8)
        let previous = try #require(source.range(of: "let previous = lastResult"))
        let replaced = try #require(source.range(of: "lastResult = current"))
        #expect(previous.lowerBound < replaced.lowerBound, "the earlier round is kept before it is replaced")
        #expect(source.contains("names: current.outdatedDisplayNames(policies: policies, newSince: previous)"))
    }

    private static func path(_ relative: String, file: String = #filePath) -> String {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(relative).path
    }
}
