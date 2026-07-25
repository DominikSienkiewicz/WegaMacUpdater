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
    /// the scan/upgrade actions in `ScanStore+Actions.swift` — and is read as one text so
    /// that a `!contains` guard still covers the whole type: pinned to one half only, the
    /// pattern it forbids could reappear in the other and the assertion would pass.
    private func scanStore() throws -> String {
        try source("ScanStore.swift") + "\n" + source("ScanStore+Actions.swift")
    }

    /// The bug itself, and the fix: the chain is fed a map resolved **in this run**, not
    /// whatever the last full scan happened to leave behind.
    @Test func theUpgradeResolvesBundlesFreshlyBeforeSnapshotting() throws {
        let text = try scanStore()
        #expect(text.contains("await refreshCaskAppPaths(caskNames)"),
                "REL-03: the upgrade must re-resolve the `.app` paths itself, before the snapshot")
        #expect(text.contains("private func refreshCaskAppPaths(_ tokens: [String]) async"),
                "REL-03: that resolution is a step of the upgrade, not a leftover of the scan")

        // Order is the whole point: resolving *after* the snapshot would protect nothing.
        let refresh = try #require(text.range(of: "await refreshCaskAppPaths(caskNames)"))
        let snapshot = try #require(text.range(of: "let snapshots = snapshotCasks(caskNames)"))
        #expect(refresh.lowerBound < snapshot.lowerBound,
                "REL-03: the paths must be resolved before the snapshot is taken")

        // Snapshot and canary must read the same map, or `verify` skips tokens the guard
        // has just cloned — the second half of the same hole.
        #expect(text.contains("CaskRollbackGuard.snapshot(tokens: tokens, appPaths: caskIconPaths)"),
                "REL-03: the snapshot reads the refreshed map")
        #expect(text.contains("CaskRollbackGuard.verify(tokens: tokens, appPaths: caskIconPaths, snapshots: snapshots)"),
                "REL-03: and the canary reads that same refreshed map")
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
