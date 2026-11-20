import Foundation
import Testing
import MacUpdaterCore
import WegaTestSupport
@testable import WegaMacUpdater

/// Swift Testing runs suites in parallel, in one process. A test that forced a language by
/// writing the process-wide `LocalizedStrings.current` switched it for every test running at
/// the same moment, so suites comparing translated strings failed intermittently. A detached
/// task stands in for such a parallel test: it inherits nothing from the task that forced the
/// language, exactly like a test in another suite.
@Suite("Language scope")
struct LanguageScopeTests {

    private let close = "Zamknij"

    @Test func aForcedLanguageStaysInsideTheTestThatForcedIt() async {
        await withLanguage(.en) {
            #expect(tr(close) == "Close")
            let seenByAParallelTest = await Task.detached { [close] in tr(close) }.value
            #expect(seenByAParallelTest == close)
        }
    }

    @MainActor
    @Test func aLanguageManagerInsideTheScopeLeavesParallelTestsAlone() async {
        let (defaults, teardown) = TestDefaults.isolated("language-scope-manager")
        defer { teardown() }

        await withLanguage(.pl) {
            let manager = LocalizationManager(defaults: defaults)
            manager.language = .en
            #expect(tr(close) == "Close")
            let seenByAParallelTest = await Task.detached { [close] in tr(close) }.value
            #expect(seenByAParallelTest == close)
        }
    }

    /// Each suite used to carry its own helper that wrote the process-wide language; one such
    /// helper is enough to bring the race back, wherever it lives.
    @Test func noTestWritesTheProcessWideLanguage() throws {
        let tests = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = (FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "positive control: the walk must reach both test targets")

        let writers = try files.filter { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("LocalizedStrings.current") else { return false }
            return text.split(separator: "\n").contains { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && line.contains(/LocalizedStrings\.current\s*=(?!=)/)
            }
        }
        #expect(writers.map(\.lastPathComponent).sorted() == [], "force a language with withLanguage(_:_:)")
    }
}
