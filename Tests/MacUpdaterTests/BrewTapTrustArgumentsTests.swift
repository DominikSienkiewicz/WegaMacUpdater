import Foundation
import Testing
@testable import MacUpdaterCore

/// The commands behind the tap-trust buttons. Tap, cask and formula names come from
/// Homebrew's own output and install receipts — data, not code — so each vector fences them
/// off from Homebrew's option parser with `--`, which `brew untap` and `brew trust` share with
/// every other brew command (Homebrew's `CLI::Parser` splits named arguments at `--`).
@Suite("Tap trust — brew argument vectors")
struct BrewTapTrustArgumentsTests {
    @Test func givenUnusedTapsWhenUntappingThenTheTapsFollowTheFence() {
        #expect(BrewService.untapArguments(taps: ["manaflow-ai/cmux", "steipete/tap"])
                == ["untap", "--", "manaflow-ai/cmux", "steipete/tap"])
    }

    @Test func givenInstalledCasksWhenTrustingThenOnlyThoseCasksAreTrusted() {
        #expect(BrewService.trustCaskArguments(names: ["steipete/tap/codexbar"])
                == ["trust", "--cask", "--", "steipete/tap/codexbar"])
    }

    @Test func givenInstalledFormulaeWhenTrustingThenOnlyThoseFormulaeAreTrusted() {
        #expect(BrewService.trustFormulaArguments(names: ["steipete/tap/peekaboo"])
                == ["trust", "--formula", "--", "steipete/tap/peekaboo"])
    }
}
