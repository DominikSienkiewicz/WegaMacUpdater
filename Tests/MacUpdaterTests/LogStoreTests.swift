import XCTest
@testable import MacUpdaterCore

final class LogStoreTests: XCTestCase {

    func testLineRoundTripForEveryLevelAndCategory() {
        let date = Date(timeIntervalSince1970: 1_749_490_441) // stały punkt
        for level in LogLevel.allCases {
            for category in LogCategory.allCases {
                let entry = LogEntry(id: UUID(), date: date, level: level,
                                     category: category, message: "hello world")
                let line = entry.fileLine
                let parsed = LogEntry.parse(line)
                XCTAssertNotNil(parsed, "nie sparsowano: \(line)")
                XCTAssertEqual(parsed?.level, level)
                XCTAssertEqual(parsed?.category, category)
                XCTAssertEqual(parsed?.message, "hello world")
                XCTAssertEqual(Int(parsed!.date.timeIntervalSince1970),
                               Int(date.timeIntervalSince1970))
            }
        }
    }

    func testNewlinesInMessageAreFlattened() {
        let entry = LogEntry(id: UUID(), date: Date(), level: .error,
                             category: .homebrew, message: "linia 1\nlinia 2")
        XCTAssertFalse(entry.fileLine.contains("\n"))
        XCTAssertEqual(LogEntry.parse(entry.fileLine)?.message, "linia 1 linia 2")
    }

    func testParseRejectsMalformedLine() {
        XCTAssertNil(LogEntry.parse("to nie jest log"))
        XCTAssertNil(LogEntry.parse(""))
    }

    // Regression: the test suite was writing into the user's REAL log file
    // (~/Library/Logs/WegaMacUpdater/wega.log) because several tests exercise
    // LogStore.shared (via WegaLog / the `logged` wrapper) and `.shared` defaulted
    // to the real Logs directory. Under XCTest it must redirect to a temp location.
    private var realUserLogDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WegaMacUpdater").path
    }

    func testDefaultDirectoryIsRedirectedUnderTests() {
        XCTAssertNotEqual(LogStore.defaultDirectory.path, realUserLogDir)
        XCTAssertTrue(LogStore.defaultDirectory.path.contains("WegaMacUpdaterTests"),
                      "expected a temp test dir, got \(LogStore.defaultDirectory.path)")
    }

    @MainActor
    func testSharedStoreDoesNotWriteToRealUserLogDuringTests() {
        XCTAssertFalse(
            LogStore.shared.logFileURL.path.hasPrefix(realUserLogDir),
            "LogStore.shared must not touch the real user log during tests; got \(LogStore.shared.logFileURL.path)"
        )
    }

    @MainActor
    private func makeStore() -> (LogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-logtest-\(UUID().uuidString)", isDirectory: true)
        let store = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 400, loadTailLines: 100)
        return (store, dir)
    }

    @MainActor
    func testAppendTrimsToMemoryCapKeepingNewest() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<8 {
            store.append(LogEntry(date: Date(), level: .info, category: .app, message: "m\(i)"))
        }
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertEqual(store.entries.first?.message, "m3")
        XCTAssertEqual(store.entries.last?.message, "m7")
    }

    @MainActor
    func testFilePersistsAndLoadsBack() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.append(LogEntry(date: Date(), level: .error, category: .homebrew, message: "boom"))
        store.flushForTests()
        let reloaded = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 400, loadTailLines: 100)
        XCTAssertEqual(reloaded.entries.last?.message, "boom")
        XCTAssertEqual(reloaded.entries.last?.level, .error)
    }

    @MainActor
    func testRotationKeepsRecentEntryAndCreatesBackup() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<60 {
            store.append(LogEntry(date: Date(), level: .info, category: .scanner,
                                  message: "wpis numer \(i) z trochę dłuższym tekstem"))
        }
        store.flushForTests()
        let backup = dir.appendingPathComponent("wega.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "brak backupu po rotacji")
        let reloaded = LogStore(directory: dir, memoryCap: 100, fileMaxBytes: 400, loadTailLines: 100)
        XCTAssertEqual(reloaded.entries.last?.message, "wpis numer 59 z trochę dłuższym tekstem")
    }

    @MainActor
    func testClearEmptiesEntriesAndFile() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.append(LogEntry(date: Date(), level: .info, category: .app, message: "x"))
        store.flushForTests()
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        let reloaded = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 400, loadTailLines: 100)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    @MainActor
    func testCorruptLineInFileIsSkippedOnLoad() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wega.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = LogEntry(date: Date(), level: .warning, category: .network, message: "ok")
        try? "śmieci\n\(good.fileLine)\nwięcej śmieci\n".write(to: url, atomically: true, encoding: .utf8)
        let reloaded = LogStore(directory: dir, memoryCap: 5, fileMaxBytes: 400, loadTailLines: 100)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.message, "ok")
    }

    @MainActor
    func testWegaLogWritesToSharedStore() async {
        let before = LogStore.shared.entries.count
        WegaLog.error(.homebrew, "test-fasady-123")
        await Task.yield()
        let added = LogStore.shared.entries.suffix(from: before)
        XCTAssertTrue(added.contains { $0.message == "test-fasady-123" && $0.level == .error && $0.category == .homebrew })
    }

    @MainActor
    func testScannerLoggedWrapperLogsOnFailure() async {
        let before = LogStore.shared.entries.count
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/TestApp.app"),
            name: "TestApp",
            bundleIdentifier: nil,
            version: nil,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
        let wrapped = ManualUpdateScanner.logged("GitHub", app) { .failed }
        let result = await wrapped()
        await Task.yield()
        XCTAssertEqual(result, .failed)
        let added = LogStore.shared.entries.suffix(from: before)
        XCTAssertTrue(added.contains { $0.message.contains("GitHub") && $0.message.contains("TestApp") && $0.level == .error })
    }

    @MainActor
    func testScannerLoggedWrapperWarnsOnUnavailable() async {
        let before = LogStore.shared.entries.count
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/TestApp.app"),
            name: "TestApp", bundleIdentifier: "com.test.app", version: "1.0",
            installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        let wrapped = ManualUpdateScanner.logged("Antigravity", app) { .unavailable }
        let result = await wrapped()
        await Task.yield()
        XCTAssertEqual(result, .unavailable)
        let added = LogStore.shared.entries.suffix(from: before)
        XCTAssertTrue(added.contains { $0.message.contains("Antigravity") && $0.message.contains("TestApp") && $0.level == .warning })
        XCTAssertFalse(added.contains { $0.message.contains("Antigravity · TestApp") && $0.level == .error })
    }

    @MainActor
    func testScannerLoggedWrapperSilentOnSuccess() async {
        let before = LogStore.shared.entries.count
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/TestApp.app"),
            name: "TestApp",
            bundleIdentifier: nil,
            version: nil,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
        let wrapped = ManualUpdateScanner.logged("GitHub", app) { .upToDate }
        _ = await wrapped()
        await Task.yield()
        let added = LogStore.shared.entries.suffix(from: before)
        XCTAssertFalse(added.contains { $0.message.contains("GitHub · TestApp") })
    }
}
