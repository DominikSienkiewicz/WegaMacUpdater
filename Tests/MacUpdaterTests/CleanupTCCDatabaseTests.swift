import SQLite3
import XCTest
@testable import MacUpdaterCore

final class CleanupTCCDatabaseTests: XCTestCase {
    private var temporaryFolder: URL!
    private var writers: [OpaquePointer] = []

    override func setUpWithError() throws {
        temporaryFolder = FileManager.default.temporaryDirectory
            .appending(path: "CleanupTCC-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for writer in writers { sqlite3_close_v2(writer) }
        writers = []
        try? FileManager.default.removeItem(at: temporaryFolder)
    }

    private static let accessTable = """
        CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, \
        auth_reason INTEGER, csreq BLOB)
        """

    @discardableResult
    private func makeDatabase(
        at url: URL? = nil,
        setup: [String],
        keepOpen: Bool = false
    ) throws -> URL {
        let target = url ?? temporaryFolder.appending(path: "TCC.db", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(target.path, &handle), SQLITE_OK)
        let connection = try XCTUnwrap(handle)
        for statement in setup {
            XCTAssertEqual(sqlite3_exec(connection, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        if keepOpen { writers.append(connection) } else { sqlite3_close_v2(connection) }
        return target
    }

    private func twoRows(extra: [String] = []) -> [String] {
        [Self.accessTable]
            + extra
            + [
                "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDocumentsFolder', '/Users/a/bin/tool', 1, 2, 0, NULL)",
                "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDownloadsFolder', 'com.example.app', 0, 0, 0, NULL)"
            ]
    }

    private let expectedTwo = [
        CleanupTCCRow(
            service: "kTCCServiceSystemPolicyDocumentsFolder", client: "/Users/a/bin/tool", clientType: 1, authValue: 2
        ),
        CleanupTCCRow(
            service: "kTCCServiceSystemPolicyDownloadsFolder", client: "com.example.app", clientType: 0, authValue: 0
        )
    ]

    private func sorted(_ rows: [CleanupTCCRow]) -> [CleanupTCCRow] {
        rows.sorted { $0.service < $1.service }
    }

    func testReadsOnlyTheRequestedServices() throws {
        let url = try makeDatabase(setup: twoRows() + [
            "INSERT INTO access VALUES ('kTCCServiceCamera', 'com.example.cam', 0, 2, 0, NULL)"
        ])
        let rows = try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents, .downloads])
        XCTAssertEqual(sorted(rows), expectedTwo)
    }

    func testEmptyServiceListReturnsNothingWithoutOpeningTheDatabase() throws {
        let missing = temporaryFolder.appending(path: "absent.db", directoryHint: .notDirectory)
        XCTAssertEqual(try SQLiteCleanupTCCDatabase(fileURL: missing).rows(for: []), [])
    }

    func testRowsWithoutAClientAreSkipped() throws {
        let url = try makeDatabase(setup: [
            Self.accessTable,
            "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDocumentsFolder', NULL, 1, 2, 0, NULL)",
            "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDocumentsFolder', '/Users/a/bin/tool', 1, 2, 0, NULL)"
        ])
        XCTAssertEqual(
            try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents]),
            [expectedTwo[0]]
        )
    }

    func testClientWithAnEmbeddedNulIsSkipped() throws {
        let url = try makeDatabase(setup: [
            Self.accessTable,
            "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDocumentsFolder', '/x/tool' || char(0) || '/evil', 1, 2, 0, NULL)",
            "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDocumentsFolder', '/Users/a/bin/tool', 1, 2, 0, NULL)"
        ])
        XCTAssertEqual(
            try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents]),
            [expectedTwo[0]]
        )
    }

    func testNullClientTypeOrAuthValueIsSkipped() throws {
        let url = try makeDatabase(setup: [
            Self.accessTable,
            "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDocumentsFolder', '/a', NULL, 2, 0, NULL)",
            "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDocumentsFolder', '/b', 1, NULL, 0, NULL)",
            "INSERT INTO access VALUES ('kTCCServiceSystemPolicyDocumentsFolder', '/Users/a/bin/tool', 1, 2, 0, NULL)"
        ])
        XCTAssertEqual(
            try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents]),
            [expectedTwo[0]]
        )
    }

    func testMissingAuthValueIsUnsupported() throws {
        let url = try makeDatabase(setup: [
            "CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, allowed INTEGER)"
        ])
        XCTAssertThrowsError(try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents])) {
            XCTAssertEqual($0 as? CleanupTCCDatabaseError, .unsupportedSchema)
        }
    }

    func testMissingAccessTableIsUnsupported() throws {
        let url = try makeDatabase(setup: ["CREATE TABLE other (service TEXT)"])
        XCTAssertThrowsError(try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents])) {
            XCTAssertEqual($0 as? CleanupTCCDatabaseError, .unsupportedSchema)
        }
    }

    func testNonDatabaseFileIsUnreadable() throws {
        let url = temporaryFolder.appending(path: "TCC.db", directoryHint: .notDirectory)
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents])) {
            XCTAssertEqual($0 as? CleanupTCCDatabaseError, .unreadable)
        }
    }

    func testMissingFileIsUnreadableAndNotCreated() {
        let url = temporaryFolder.appending(path: "TCC.db", directoryHint: .notDirectory)
        XCTAssertThrowsError(try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents])) {
            XCTAssertEqual($0 as? CleanupTCCDatabaseError, .unreadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWALDatabaseWithAnOpenWriterIsReadable() throws {
        let url = try makeDatabase(setup: twoRows(extra: ["PRAGMA journal_mode=WAL"]), keepOpen: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"), "the database is not in WAL mode")
        let before = try Data(contentsOf: url)
        let rows = try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents, .downloads])
        XCTAssertEqual(sorted(rows), expectedTwo)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testReadLeavesTheDatabaseBytesUnchanged() throws {
        let url = try makeDatabase(setup: twoRows())
        let before = try Data(contentsOf: url)
        let rows = try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents, .downloads])
        XCTAssertEqual(sorted(rows), expectedTwo)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-journal"))
    }

    func testPathWithSpacesOpens() throws {
        let url = temporaryFolder
            .appending(path: "Library/Application Support/com.apple.TCC #1%/TCC.db", directoryHint: .notDirectory)
        try makeDatabase(at: url, setup: twoRows())
        let rows = try SQLiteCleanupTCCDatabase(fileURL: url).rows(for: [.documents, .downloads])
        XCTAssertEqual(sorted(rows), expectedTwo)
    }

    func testHomeInitPointsAtTheUserDatabase() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        XCTAssertEqual(
            SQLiteCleanupTCCDatabase(home: home).fileURL.path,
            home.path + "/Library/Application Support/com.apple.TCC/TCC.db"
        )
    }
}
