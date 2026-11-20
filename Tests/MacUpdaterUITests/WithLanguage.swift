import MacUpdaterCore
@testable import WegaMacUpdater

/// Runs `body` with `language` as the active UI language for this test only. Swift Testing runs
/// suites in parallel in one process, so every test that needs a particular language goes
/// through this helper instead of writing the process-wide `LocalizedStrings.current` itself.
func withLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
    try LocalizedStrings.withScopedLanguage(language, body)
}

/// The `async` form of `withLanguage(_:_:)`, for a body that awaits.
func withLanguage<T>(
    _ language: AppLanguage,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> T {
    try await LocalizedStrings.withScopedLanguage(language, isolation: isolation, body)
}
