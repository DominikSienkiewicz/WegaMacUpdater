import Testing
import Foundation
@testable import MacUpdaterCore

/// QA-01h — regression guard for the REL-09 promise, pinned as one of `QA-01`'s "🎯
/// Najważniejsze nowe scenariusze": a scan that could not hear from every source is written
/// to disk as *incomplete*, and the next launch that restores it must not quietly upgrade it
/// to "complete".
///
/// The bug this stands against was reassuring precisely because it survived a restart: a
/// `brew update` cut short by a network outage was thrown away, the missing Brew answer was
/// persisted as an empty list, and the relaunched window painted *"Wszystko aktualne"* over a
/// scan that had established nothing of the sort. REL-09 made completeness a *stored* fact so
/// a failed scan still reads as failed after the process that took it is long gone.
///
/// The restart is modelled where it actually happens — the ``ScanResultStore`` seam: the
/// running app persists the snapshot, the next launch reads the same bytes back through a
/// brand-new store. The in-memory ``ScanSnapshotIO`` double stands in for the on-disk file so
/// the scenario runs without touching the filesystem.
@Suite("QA01HRestoredScanStaysIncomplete")
struct QA01HRestoredScanStaysIncompleteTests {

    /// The process boundary a restart crosses: bytes written by one launch, read by the next.
    private final class InMemoryScanSnapshotIO: ScanSnapshotIO {
        var storedData: Data?
        func read() throws -> Data? { storedData }
        func write(_ data: Data) throws { storedData = data }
    }

    /// A scan cut short by a network outage: neither `brew update` nor `brew outdated`
    /// answered, so two sources are `.failed`. Such a scan cannot claim the machine is current
    /// — ``ScanSnapshot/isComplete`` is `false`, derived from the per-source reports.
    private func scanWithAFailedSource(scannedAt: Date) -> ScanSnapshot {
        ScanSnapshot(
            scannedAt: scannedAt,
            brew: nil,
            mas: [], npm: [], manual: [],
            sources: ScanSourceReports(
                brewMetadata: ScanSourceReport(outcome: .failed("brew update"),
                                               error: "brew update: network is unreachable"),
                brew: ScanSourceReport(outcome: .failed("brew outdated"),
                                       error: "brew outdated: network is unreachable")
            )
        )
    }

    @Test("a failed scan restored after a restart stays marked as incomplete")
    func aFailedScanStaysIncompleteAcrossARestart() throws {
        let io = InMemoryScanSnapshotIO()
        let scannedAt = Date(timeIntervalSince1970: 1_749_490_441)

        // Incomplete the moment it is taken — a source failed.
        let scan = scanWithAFailedSource(scannedAt: scannedAt)
        #expect(scan.isComplete == false)

        // The running app persists it...
        try ScanResultStore(io: io).save(scan)

        // ...and the next launch — a fresh store over the same bytes — restores it.
        let restored = try #require(ScanResultStore(io: io).load(),
                                    "the persisted scan must be restorable after a restart")

        #expect(restored.isComplete == false,
                "REL-09: a scan that failed before the restart must not come back looking complete")
        #expect(restored.sources.failedSourceCount == 2,
                "REL-09: the failed sources are what make it incomplete, and they survive the restart")
        #expect(restored.sources.brew?.error == "brew outdated: network is unreachable",
                "REL-09: the failure is restored in the source's own words, not flattened away")
    }
}
