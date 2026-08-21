import Testing
import Foundation
@testable import MacUpdaterCore

/// A selection of several updates runs its processes side by side.
///
/// The window's upgrade path lives behind a live `BrewService` a unit test cannot stand in
/// for, so — as `UpdatePlanFidelityTests` does for REL-04 — the wiring is asserted against
/// the source of the type itself.
@Suite("ConcurrentUpdateRun")
struct ConcurrentUpdateRunTests {

    private func scanStore() throws -> String { try ScanStoreSources.everything() }

    /// The regression: casks used to go out as one `brew upgrade --cask a b c`, which brew
    /// then installed one at a time. Each row now owns its process.
    @Test func casksAreNotUpgradedAsOneBatch() throws {
        let text = try scanStore()
        #expect(text.contains("caskUpgradeCommand(tokens: [token])"),
                "each cask must be upgraded by its own brew process, one token per call")
        #expect(!text.contains("caskUpgradeCommand(tokens: caskNames)"),
                "a batched cask upgrade is the sequential behaviour this replaced")
    }

    /// The pool cap is the shared constant, never a number written at the call site.
    @Test func thePoolUsesTheSharedLimit() throws {
        let text = try scanStore()
        #expect(text.contains("MacUpdaterConstants.maxConcurrentUpgrades"),
                "the concurrency limit belongs in one place")
        #expect(MacUpdaterConstants.maxConcurrentUpgrades == 3)
    }

    /// The four lanes overlap. Handing them all to the pool at once is what makes an npm
    /// package upgrade while brew is still working, which is most of the wall-clock this
    /// change buys.
    @Test func theLanesStartTogether() throws {
        let text = try scanStore()
        #expect(text.contains("[@MainActor @Sendable () async -> UpgradeLaneOutput]"),
                "the lanes must be handed to the pool together, not awaited one after another")
        #expect(text.contains("runBoundedOnMainActor(limit: 0, lanes)"),
                "the four lanes are four different tools — nothing to cap between them")
    }

    /// The tracker keeps one line buffer and one in-flight token; several concurrent streams
    /// would corrupt both. Only the single formula call may stream into it.
    @Test func onlyOneCallStreamsIntoTheProgressTracker() throws {
        let text = try scanStore()
        let occurrences = text.components(separatedBy: "streamsProgress: true").count - 1
        #expect(occurrences == 1,
                "exactly one call site may feed the tracker's stream parser, found \(occurrences)")
    }

    /// A cask that may raise an admin-password prompt has to be recognised before the pool
    /// is filled, not after two Touch ID sheets are already on screen.
    @Test func theAdminPasswordLaneIsWiredToTheProfile() throws {
        let text = try scanStore()
        #expect(text.contains("CaskUpgradeLanes(tokens: preparation.trustedCaskNames, profiles: caskProfiles)"),
                "the serial lane must be derived from the scanned artifact profiles")
    }

    /// REL-12 — a queued row that never started is skipped, and a skipped row reports
    /// nothing: `nil` is what keeps "never attempted" apart from "attempted and failed".
    @Test func aRowStoppedInTheQueueReportsNothing() throws {
        let text = try scanStore()
        #expect(text.contains("LaneItemResult(item: item, outcome: nil)"),
                "a row the stop switch caught before it started carries no outcome")
        #expect(text.contains("guard let outcome = result.outcome else { return }"),
                "folding must skip a row that was never attempted")
    }
}
