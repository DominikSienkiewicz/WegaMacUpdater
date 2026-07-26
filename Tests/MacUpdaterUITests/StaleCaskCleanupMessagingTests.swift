import Testing
@testable import WegaMacUpdater

/// REL-13 — cleaning up stale casks used to announce success unconditionally: a full failure
/// still showed "Usunięto 0 nieaktualnych casków" behind a success checkmark. This suite pins
/// that the message now branches on the real outcome — success, partial result, and failure
/// each get their own honest banner, and a full failure is never dressed up as success.
///
/// `BrewService` is a concrete class with no protocol seam and `brew` cannot run in tests, so
/// the outcome→banner mapping is the unit under test (the same shape as `SelfUpdatePresentation`
/// and `BrewUpgradeOutcome`). Assertions rely on the banner variant and on the three messages
/// being distinct, both of which hold regardless of the active language.
@Suite("Stale-cask cleanup messaging")
@MainActor
struct StaleCaskCleanupMessagingTests {

    @Test func classifiesAFullFailureAsFailureNotSuccess() {
        #expect(StaleCaskCleanupOutcome.classify(removed: 0, failed: 3) == .failure(failed: 3))
    }

    @Test func classifiesAMixedRunAsPartial() {
        #expect(StaleCaskCleanupOutcome.classify(removed: 2, failed: 1) == .partial(removed: 2, failed: 1))
    }

    @Test func classifiesACleanRunAsSuccess() {
        #expect(StaleCaskCleanupOutcome.classify(removed: 3, failed: 0) == .success(removed: 3))
    }

    /// AC — a full failure ("Usunięto 0") must not be communicated as a success.
    @Test func aFailedRunReportsFailureNotSuccess() {
        let failure = StaleCaskCleanupPresentation.banner(for: .failure(failed: 3))
        let successWithNothingRemoved = StaleCaskCleanupPresentation.banner(for: .success(removed: 0))
        #expect(failure.variant == .danger)
        #expect(failure.title != successWithNothingRemoved.title)
        #expect(failure.action == .openLogs)
    }

    /// AC — a partial run gets its own message, distinct from both success and failure.
    @Test func aPartialRunReportsAPartialResult() {
        let partial = StaleCaskCleanupPresentation.banner(for: .partial(removed: 2, failed: 1))
        let success = StaleCaskCleanupPresentation.banner(for: .success(removed: 2))
        let failure = StaleCaskCleanupPresentation.banner(for: .failure(failed: 1))
        #expect(partial.variant == .danger)
        #expect(partial.title != success.title)
        #expect(partial.title != failure.title)
    }

    @Test func aCleanRunStillReportsSuccess() {
        let banner = StaleCaskCleanupPresentation.banner(for: .success(removed: 3))
        #expect(banner.variant == .success)
    }

    /// AC — the message distinguishes success, partial result and failure.
    @Test func theThreeOutcomesProduceThreeDistinctMessages() {
        let success = StaleCaskCleanupPresentation.banner(for: .success(removed: 1))
        let partial = StaleCaskCleanupPresentation.banner(for: .partial(removed: 1, failed: 1))
        let failure = StaleCaskCleanupPresentation.banner(for: .failure(failed: 1))
        #expect(Set([success.title, partial.title, failure.title]).count == 3)
    }
}
