import XCTest
@testable import MacUpdaterCore

final class CleanupKeptCopiesTests: XCTestCase {
    func testRoundTripAndCorruptData() throws {
        let suite = "CleanupKeptCopiesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let copies = [
            "ollama": CleanupKeptCopy(path: "/opt/homebrew/bin/ollama", source: .homebrewFormula(name: "ollama")),
            "tool": CleanupKeptCopy(path: "/Users/me/.local/bin/tool", source: .packageManager(.pipx)),
        ]

        XCTAssertEqual(CleanupKeptCopies.load(from: defaults), [:])
        CleanupKeptCopies.save(copies, to: defaults)
        XCTAssertNotNil(defaults.data(forKey: CleanupKeptCopies.defaultsKey), "stored as JSON data")
        XCTAssertEqual(CleanupKeptCopies.load(from: defaults), copies)

        defaults.set(Data("not json".utf8), forKey: CleanupKeptCopies.defaultsKey)
        XCTAssertEqual(CleanupKeptCopies.load(from: defaults), [:])
        defaults.set("a string", forKey: CleanupKeptCopies.defaultsKey)
        XCTAssertEqual(CleanupKeptCopies.load(from: defaults), [:])
        XCTAssertEqual(CleanupKeptCopies.defaultsKey, "cleanup.keptCopies")
    }
}
