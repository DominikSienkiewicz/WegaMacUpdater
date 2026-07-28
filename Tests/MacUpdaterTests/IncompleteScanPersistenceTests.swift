import Testing
import Foundation
@testable import MacUpdaterCore

/// REL-09 — a scan that could not hear from every source must still look like one after a
/// restart.
///
/// Three things conspired to hide it: the `brew update` failure was thrown away with
/// `_ = try?`, the persisted snapshot recorded no per-source result at all, and a missing
/// Brew answer was written to disk as an **empty list**. Relaunch after a network outage
/// and the window painted the most reassuring screen it has — *"Wszystko aktualne"* — over
/// a scan that had established nothing of the sort.
///
/// The snapshot's own shape is asserted behaviourally in `ScanResultStoreTests`; what
/// cannot be unit-tested is the wiring in the app target (the scan shells out and hits the
/// network), so it is pinned at source level, as `UpdateResultHonestyTests` does for REL-02.
@Suite("IncompleteScanPersistence")
struct IncompleteScanPersistenceTests {

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

    /// The metadata refresh is the source a network outage takes out first, and its result
    /// was discarded on the spot.
    @Test func theMetadataRefreshResultIsNotThrownAway() throws {
        let text = try scanStore()
        #expect(!text.contains("_ = try? await model.brewService.update()"),
                "REL-09: a failed `brew update` must be recorded and shown, not swallowed by `try?`")
        #expect(text.contains("brewMetadata"),
                "REL-09: the metadata refresh is a source of the scan and needs its own result")
    }

    /// "Brew said nothing" and "Brew said nothing is outdated" are different facts, and the
    /// snapshot used to store both as an empty list.
    @Test func aMissingBrewAnswerIsNotPersistedAsAnEmptyList() throws {
        let text = try scanStore()
        #expect(!text.contains("brew: brewOutdated ?? BrewOutdated(formulae: [], casks: [])"),
                "REL-09: a missing Brew result must persist as absent, never as `no updates`")
    }

    /// What the restored scan knows about itself, and what it does with it.
    @Test func theRestoredScanCarriesItsOwnCompleteness() throws {
        let text = try scanStore()
        #expect(text.contains("sources: sourceReports"),
                "REL-09: the per-source results are part of what gets persisted")
        #expect(text.contains("lastScanComplete"),
                "REL-09: the store must expose whether the result on screen came from a complete scan")
        #expect(text.contains("snapshot.isComplete"),
                "REL-09: restoring a scan restores the fact that it was incomplete")
    }

    /// The screen that made the false claim: an empty list is only "everything is up to
    /// date" when the scan behind it actually completed.
    @Test func anIncompleteScanIsNotRenderedAsEverythingUpToDate() throws {
        let text = try source("UpdateView.swift")
        #expect(text.contains("scan.lastScanComplete"),
                "REL-09: the empty-state hero must ask whether the scan was complete before claiming it")
    }
}
