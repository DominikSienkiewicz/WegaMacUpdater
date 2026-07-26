import Testing
@testable import MacUpdaterCore

/// REL-08 — `brew install --cask --force <token>` overwrites the app on disk, so a wrong
/// `.app`→cask match replaces the user's program with a different one. The match confidence
/// must therefore gate the takeover — `CaskMatchConfidence.allowsAutoConfirm` finally gets a
/// production consumer instead of only painting a badge.
@Suite("MigrationAutoTakeover")
struct MigrationAutoTakeoverTests {
    @Test func highConfidenceIsAllowedToTakeOverAutomatically() {
        #expect(MigrationAutoTakeover.decide(.high) == .allowed)
    }

    @Test func mediumConfidenceRequiresExplicitConfirmation() {
        #expect(MigrationAutoTakeover.decide(.medium) == .requiresConfirmation)
    }

    @Test func lowConfidenceIsBlocked() {
        #expect(MigrationAutoTakeover.decide(.low) == .blocked)
    }

    /// The decision is defined in terms of `allowsAutoConfirm`, so only the level that
    /// permits auto-confirm may be `.allowed`.
    @Test func onlyTheAutoConfirmLevelIsAllowed() {
        for confidence in [CaskMatchConfidence.low, .medium, .high] {
            let isAllowed = MigrationAutoTakeover.decide(confidence) == .allowed
            #expect(isAllowed == confidence.allowsAutoConfirm)
        }
    }
}
