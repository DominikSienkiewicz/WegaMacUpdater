import XCTest
@testable import MacUpdaterCore

final class ScanResultStoreTests: XCTestCase {

    // MARK: In-memory fake I/O seam — the suite NEVER touches the disk.

    private final class InMemoryScanSnapshotIO: ScanSnapshotIO {
        var storedData: Data?
        var readError: Error?
        var writeError: Error?

        func read() throws -> Data? {
            if let readError { throw readError }
            return storedData
        }

        func write(_ data: Data) throws {
            if let writeError { throw writeError }
            storedData = data
        }
    }

    private enum FakeIOError: Error { case boom }

    // A snapshot that exercises every payload list, including a manual app whose
    // `UpdateSource` carries an associated value and a non-default `origin`.
    private func makeSnapshot(scannedAt: Date, schemaVersion: Int = ScanSnapshot.currentSchemaVersion) -> ScanSnapshot {
        ScanSnapshot(
            scannedAt: scannedAt,
            brew: BrewOutdated(
                formulae: [BrewOutdatedItem(name: "wget", installedVersions: ["1.21.3"], currentVersion: "1.21.4")],
                casks: [BrewOutdatedItem(name: "iterm2", installedVersions: ["3.4"], currentVersion: "3.5", pinned: false, autoUpdates: true)]
            ),
            mas: [MasOutdatedApp(appStoreID: "497799835", name: "Xcode", installedVersion: "15.0", currentVersion: "15.4")],
            npm: [NpmGlobalOutdated(name: "typescript", installedVersion: "5.3.0", latestVersion: "5.5.0")],
            manual: [
                ManualOutdatedApp(
                    name: "Ghostty",
                    path: URL(fileURLWithPath: "/Applications/Ghostty.app"),
                    installedVersion: "1.0.0",
                    availableVersion: "1.1.0",
                    source: .github(repo: "ghostty-org/ghostty"),
                    origin: .brew,
                    releaseNotes: "security fix"
                )
            ],
            schemaVersion: schemaVersion
        )
    }

    func testRoundTripReturnsTheSameSnapshot() throws {
        let io = InMemoryScanSnapshotIO()
        let store = ScanResultStore(io: io)
        let snapshot = makeSnapshot(scannedAt: Date(timeIntervalSince1970: 1_749_490_441))

        try store.save(snapshot)
        let loaded = store.load()

        XCTAssertEqual(loaded, snapshot)
    }

    func testSaveOverwritesPreviousSnapshot() throws {
        let io = InMemoryScanSnapshotIO()
        let store = ScanResultStore(io: io)

        try store.save(makeSnapshot(scannedAt: Date(timeIntervalSince1970: 1)))
        let second = makeSnapshot(scannedAt: Date(timeIntervalSince1970: 2))
        try store.save(second)

        XCTAssertEqual(store.load(), second)
    }

    func testCorruptedDataReturnsNil() {
        let io = InMemoryScanSnapshotIO()
        io.storedData = Data("this is not json {{{".utf8)
        let store = ScanResultStore(io: io)

        XCTAssertNil(store.load())
    }

    func testUnknownSchemaVersionReturnsNil() throws {
        let io = InMemoryScanSnapshotIO()
        let store = ScanResultStore(io: io)
        // Persist a well-formed snapshot stamped with a schema the current build
        // does not understand — a forward-incompatible file must fail soft.
        try store.save(makeSnapshot(scannedAt: Date(), schemaVersion: ScanSnapshot.currentSchemaVersion + 999))

        XCTAssertNil(store.load())
    }

    func testMissingDataReturnsNil() {
        let io = InMemoryScanSnapshotIO()
        let store = ScanResultStore(io: io)

        XCTAssertNil(store.load())
    }

    func testReadFailureReturnsNil() {
        let io = InMemoryScanSnapshotIO()
        io.readError = FakeIOError.boom
        let store = ScanResultStore(io: io)

        XCTAssertNil(store.load())
    }

    // MARK: REL-09 — an incomplete scan stays incomplete across a relaunch

    /// "Brew never answered" and "Brew answered: nothing is outdated" are different facts.
    /// The snapshot stored both as an empty list, which is what turned a network outage
    /// into a convincing "everything is up to date" after a restart.
    func testAMissingBrewResultRoundTripsAsAbsentNotAsAnEmptyList() throws {
        let io = InMemoryScanSnapshotIO()
        let store = ScanResultStore(io: io)
        let snapshot = ScanSnapshot(
            scannedAt: Date(timeIntervalSince1970: 1),
            brew: nil,
            mas: [], npm: [], manual: [],
            sources: ScanSourceReports(
                brew: ScanSourceReport(outcome: .failed("brew outdated"), error: "network is unreachable")
            )
        )

        try store.save(snapshot)

        XCTAssertNil(store.load()?.brew)
        XCTAssertNotEqual(store.load()?.brew, BrewOutdated(formulae: [], casks: []))
    }

    func testPerSourceResultsAndTheirErrorsSurviveTheRoundTrip() throws {
        let io = InMemoryScanSnapshotIO()
        let store = ScanResultStore(io: io)
        let sources = ScanSourceReports(
            brewMetadata: ScanSourceReport(outcome: .failed("brew update"), error: "brew update: no internet"),
            brew: ScanSourceReport(outcome: .succeeded),
            mas: ScanSourceReport(outcome: .notInstalled),
            npm: ScanSourceReport(outcome: .succeeded),
            manual: ScanSourceReport(outcome: .failed("ręczne checki"), error: "ręczne checki: 3 źródeł nie odpowiedziało")
        )

        try store.save(ScanSnapshot(scannedAt: Date(timeIntervalSince1970: 1), brew: nil,
                                    mas: [], npm: [], manual: [], sources: sources))
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.sources, sources)
        XCTAssertEqual(loaded.sources.brewMetadata?.error, "brew update: no internet")
        XCTAssertEqual(loaded.sources.errors.count, 2)
    }

    /// Completeness is stored, but it defaults to what the per-source results say, so the
    /// two cannot drift apart by omission at the call site.
    func testCompletenessDefaultsToWhatTheSourcesReport() {
        let failing = ScanSnapshot(
            scannedAt: Date(), brew: nil, mas: [], npm: [], manual: [],
            sources: ScanSourceReports(brew: ScanSourceReport(outcome: .failed("brew outdated"), error: "boom"))
        )
        let clean = ScanSnapshot(
            scannedAt: Date(), brew: BrewOutdated(formulae: [], casks: []), mas: [], npm: [], manual: [],
            sources: ScanSourceReports(brew: ScanSourceReport(outcome: .succeeded),
                                       mas: ScanSourceReport(outcome: .notInstalled))
        )

        XCTAssertFalse(failing.isComplete)
        // A tool that is not installed is *not applicable*, never a failed check (F4).
        XCTAssertTrue(clean.isComplete)
    }

    /// A scan cut short before a source ran leaves no report for it — which is not the same
    /// as that source failing, and must not be counted as one.
    func testAnAbsentReportIsNotAFailure() {
        let reports = ScanSourceReports(brew: ScanSourceReport(outcome: .succeeded))

        XCTAssertTrue(reports.isComplete)
        XCTAssertEqual(reports.failedSourceCount, 0)
        XCTAssertTrue(reports.errors.isEmpty)
    }

    func testFailedSourcesAreCountedAndTheirErrorsCollected() {
        let reports = ScanSourceReports(
            brewMetadata: ScanSourceReport(outcome: .failed("brew update"), error: "no internet"),
            brew: ScanSourceReport(outcome: .succeeded),
            npm: ScanSourceReport(outcome: .failed("npm"), error: "registry timeout")
        )

        XCTAssertFalse(reports.isComplete)
        XCTAssertEqual(reports.failedSourceCount, 2)
        XCTAssertEqual(Set(reports.errors), ["no internet", "registry timeout"])
    }

    /// A snapshot from the pre-REL-09 schema carries no per-source result, so it cannot say
    /// whether it was complete. Reading it as complete is the false reassurance the version
    /// bump exists to prevent — it fails soft, and the next scan writes a current one.
    func testAPreREL09SnapshotIsRejected() throws {
        let io = InMemoryScanSnapshotIO()
        let store = ScanResultStore(io: io)
        try store.save(makeSnapshot(scannedAt: Date(), schemaVersion: 1))

        XCTAssertNil(store.load())
    }

    func testSavePropagatesWriteError() {
        let io = InMemoryScanSnapshotIO()
        io.writeError = FakeIOError.boom
        let store = ScanResultStore(io: io)

        XCTAssertThrowsError(try store.save(makeSnapshot(scannedAt: Date())))
    }
}
