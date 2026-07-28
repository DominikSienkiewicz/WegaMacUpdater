import Testing
import Foundation

/// REL-03 — the snapshot → canary → rollback chain must also cover an upgrade started
/// from a *restored* scan, which is the most common way the app is used at all: open the
/// window, press "Zaktualizuj wszystkie".
///
/// `restoreLastScan()` brings back the lists but not `caskIconPaths` (token → `.app`),
/// which only a full `runCheck` ever fills. Reading that map at snapshot time therefore
/// yielded `[:]`: `CaskRollbackGuard.snapshot` cloned nothing and `verify` skipped every
/// token — the safety net was absent exactly where the product claims its main advantage.
///
/// The fix is to resolve the bundles **fresh, immediately before the snapshot**, through
/// the one resolver both the window and the background updater share
/// (`CaskAppPathResolver`, whose own behaviour is pinned in `CaskAppPathResolverTests`).
/// The wiring lives in the app target behind live `BrewService` values a unit test cannot
/// stand in for, so — exactly as `UpdateResultHonestyTests` does for REL-02 — it is
/// asserted at source level.
@Suite("RollbackNetAfterRestore")
struct RollbackNetAfterRestoreTests {

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/\(name)"),
                   encoding: .utf8)
    }

    /// `ScanStore`'s implementation. It spans two files — the state in `ScanStore.swift`,
    /// the actions across `ScanStore+…` — and is read as one text through `ScanStoreSources` so
    /// that a `!contains` guard still covers the whole type: pinned to one half only, the
    /// pattern it forbids could reappear in the other and the assertion would pass.
    private func scanStore() throws -> String {
        try ScanStoreSources.everything()
    }

    /// The bug itself: the chain read a map that was filled somewhere else, at some other
    /// time — and after `restoreLastScan()` was not filled at all.
    @Test func theChainNoLongerReadsTheScansIconMap() throws {
        let text = try scanStore()
        #expect(!text.contains("CaskRollbackGuard.snapshot(tokens: tokens, appPaths: caskIconPaths)"),
                "REL-03: the snapshot must not read `caskIconPaths` — it is empty after `restoreLastScan()`")
        #expect(!text.contains("CaskRollbackGuard.verify(tokens: tokens, appPaths: caskIconPaths"),
                "REL-03: `verify` must not read `caskIconPaths` either, or it skips every token")
    }

    /// The fix: one resolution, taken in this run and **passed** to both phases.
    ///
    /// A parameter rather than shared state is the whole point. Ordering no longer needs
    /// guarding — a snapshot cannot be taken without being handed the paths it covers, so a
    /// future call site added elsewhere cannot compile its way back into this bug.
    @Test func theResolvedPathsArePassedToBothPhases() throws {
        let text = try scanStore()
        #expect(text.contains("await resolveCaskAppPaths(caskNames)"),
                "REL-03: the upgrade must resolve the `.app` paths itself, in this run")
        #expect(text.contains("func snapshotCasks(\n        _ tokens: [String],\n        appPaths: [String: URL],"),
                "REL-03: the snapshot cannot be taken without being told which bundles it covers")
        #expect(text.contains("snapshotCasks(caskNames, appPaths: appPaths, operation: operation)"),
                "REL-03: the snapshot takes the freshly resolved paths")
        #expect(text.contains("postCaskUpgrade(\n                    caskNames, appPaths: appPaths, snapshots: snapshots,"),
                "REL-03: the canary verifies against the very same paths, never a second map")
    }

    /// One resolver, two callers — the duplicate hand-rolled loops are what let the window
    /// path and the unattended path disagree about where an app lives.
    @Test func bothUpgradePathsShareOneResolver() throws {
        let store = try scanStore()
        let background = try source("BackgroundUpdater.swift")
        #expect(store.contains("CaskAppPathResolver()"),
                "REL-03: the window path resolves through the shared resolver")
        #expect(background.contains("CaskAppPathResolver()"),
                "REL-03: `resolveAppPaths` was extracted, not copied")
        #expect(!background.contains("Applications/\\(artifact)"),
                "REL-03: the hand-rolled path loop in BackgroundUpdater must be gone")
        #expect(!store.contains("Applications/\\(artifact)"),
                "REL-03: and its copy in ScanStore too")
    }
}
