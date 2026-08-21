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

    // A failure's own words now ride on the entry as a structured detail instead of as N
    // loose error messages (see `ScanStore+Updating`, which moved brew's diagnostics onto
    // one entry). Searching the Logs tab for a cask name that appears only inside that
    // detail has to keep finding it — otherwise moving the text quietly deleted a search
    // that worked before.
    func testFilterBySearchMatchesTheFailureDetail() {
        let detailed = LogEntry(
            date: Date(), level: .error, category: .homebrew,
            message: "Aktualizacja niekompletna",
            detail: LogDetail(command: "brew upgrade --cask visual-studio-code",
                              exitCode: 1,
                              stderr: "Error: Failure while executing; iterm2 exited with 1.")
        )
        let plain = entry(.info, "nic ciekawego")
        let all = [detailed, plain]

        XCTAssertEqual(filterLogEntries(all, level: .all, search: "visual-studio-code").count, 1,
                       "a field value is part of what the entry says")
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "iterm2").count, 1,
                       "so is the stderr tail")
        XCTAssertEqual(filterLogEntries(all, level: .all, search: "ITERM2").count, 1,
                       "matching stays case-insensitive, like message and category")
        XCTAssertTrue(filterLogEntries(all, level: .all, search: "nieobecne").isEmpty)
    }

    // UX-06 — an empty log and a filter that hides everything are different situations and
    // must read differently. This pins the classification the LogsView renders on.
    func testEmptyReasonIsNilWhenSomethingIsVisible() {
        XCTAssertNil(logEmptyReason(totalCount: 3, visibleCount: 1))
    }

    func testEmptyReasonIsNoEntriesWhenTheLogIsGenuinelyEmpty() {
        XCTAssertEqual(logEmptyReason(totalCount: 0, visibleCount: 0), .noEntries)
    }

    func testEmptyReasonIsNoMatchesWhenEntriesExistButTheFilterHidesThemAll() {
        XCTAssertEqual(logEmptyReason(totalCount: 5, visibleCount: 0), .noFilterMatches)
    }
}
