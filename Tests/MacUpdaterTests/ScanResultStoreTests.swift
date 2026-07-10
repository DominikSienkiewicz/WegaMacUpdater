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

    func testSavePropagatesWriteError() {
        let io = InMemoryScanSnapshotIO()
        io.writeError = FakeIOError.boom
        let store = ScanResultStore(io: io)

        XCTAssertThrowsError(try store.save(makeSnapshot(scannedAt: Date())))
    }
}
