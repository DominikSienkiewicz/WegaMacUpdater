import XCTest
@testable import MacUpdaterCore

final class LogFilterTests: XCTestCase {
    private func entry(_ level: LogLevel, _ msg: String, _ cat: LogCategory = .app) -> LogEntry {
        LogEntry(date: Date(), level: level, category: cat, message: msg)
    }

    func testFilterByLevel() {
        let all = [entry(.info, "a"), entry(.warning, "b"), entry(.error, "c"), entry(.debug, "d")]
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "").count, 4)
        XCTAssertEqual(filterLogEntries(all, level: .errorsOnly, search: "").map(\.message), ["c"])
        XCTAssertEqual(Set(filterLogEntries(all, level: .warningsAndUp, search: "").map(\.message)), ["b", "c"])
    }

    func testFilterBySearchMatchesMessageAndCategory() {
        let all = [entry(.info, "hello", .homebrew), entry(.info, "world", .network)]
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "hel").map(\.message), ["hello"])
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "network").map(\.message), ["world"])
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "HELLO").map(\.message), ["hello"])
    }
}
