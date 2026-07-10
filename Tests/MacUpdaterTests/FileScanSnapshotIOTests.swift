import XCTest
@testable import MacUpdaterCore

/// `ScanResultStore` is covered against an in-memory double, which leaves the *production*
/// I/O — the code that actually writes the restored scan to Application Support — with no
/// test at all. A silent failure here loses the "instant value" of M2 without any symptom.
///
/// These exercise the real filesystem, confined to a per-test temporary directory.
final class FileScanSnapshotIOTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-io-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeIO(_ name: String = "last-scan.json") -> FileScanSnapshotIO {
        FileScanSnapshotIO(fileURL: directory.appendingPathComponent(name))
    }

    func testReadingBeforeAnythingIsWrittenReturnsNil() throws {
        XCTAssertNil(try makeIO().read())
    }

    func testWrittenBytesComeBackUnchanged() throws {
        let io = makeIO()
        let payload = Data("{\"schemaVersion\":1}".utf8)

        try io.write(payload)

        XCTAssertEqual(try io.read(), payload)
    }

    /// The Application Support subdirectory does not exist on a fresh machine. Writing has
    /// to create it, or the very first scan is never persisted.
    func testWriteCreatesMissingIntermediateDirectories() throws {
        let nested = directory
            .appendingPathComponent("WegaMacUpdater", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("last-scan.json")
        let io = FileScanSnapshotIO(fileURL: nested)

        try io.write(Data("x".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    /// A second scan must replace the first, not append to it or leave a longer tail behind.
    func testWritingTwiceReplacesTheEarlierContentEntirely() throws {
        let io = makeIO()
        try io.write(Data("a-long-first-snapshot".utf8))

        try io.write(Data("short".utf8))

        XCTAssertEqual(try io.read(), Data("short".utf8))
    }

    func testProductionPathLivesUnderApplicationSupport() {
        let url = FileScanSnapshotIO.defaultFileURL
        XCTAssertEqual(url.lastPathComponent, "last-scan.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "WegaMacUpdater")
        XCTAssertTrue(url.path.contains("Application Support"), url.path)
    }

    /// End to end through the store, on real files rather than a double.
    func testStoreRoundTripsThroughTheRealFilesystem() throws {
        let store = ScanResultStore(io: makeIO())
        let snapshot = ScanSnapshot(
            scannedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            brew: BrewOutdated(formulae: [], casks: []),
            mas: [], npm: [], manual: []
        )

        try store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }

    /// Fail-soft on a corrupt file: the window falls back to an empty state instead of
    /// crashing on launch.
    func testStoreReturnsNilForACorruptFileOnDisk() throws {
        let io = makeIO()
        try io.write(Data("not json at all".utf8))

        XCTAssertNil(ScanResultStore(io: io).load())
    }
}
