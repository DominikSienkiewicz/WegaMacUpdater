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
}
