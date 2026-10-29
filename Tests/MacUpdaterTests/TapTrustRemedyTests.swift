import Foundation
import Testing
@testable import MacUpdaterCore

/// The rule behind the tap-trust buttons: a tap something installed came from gets the
/// narrowest trust — exactly those casks and formulae, never the whole tap — and a tap nothing
/// installed came from is untapped, Homebrew's own first suggestion for an unused tap.
@Suite("Tap trust — choosing the remedy per tap")
struct TapTrustRemedyTests {
    private static let listed = ["manaflow-ai/cmux", "steipete/tap"]

    /// The user's machine: `Caskroom/cmux` exists, but its receipt says `homebrew/cask`. The
    /// token sharing the `manaflow-ai/cmux` tap's name must not count as "installed from it".
    @Test func givenACaskNamedLikeTheTapButFromAnotherTapWhenPlanningThenBothTapsAreUntapped() {
        let installed = [InstalledPackageOrigin(kind: .cask, name: "cmux", tap: "homebrew/cask")]

        let remedies = TapTrustPlanner.remedies(forUntrustedTaps: Self.listed, installed: installed)

        #expect(remedies == [
            TapTrustRemedy(kind: .untapUnused, arguments: ["untap", "--", "manaflow-ai/cmux", "steipete/tap"]),
        ])
    }

    @Test func givenItemsInstalledFromATapWhenPlanningThenOnlyThoseItemsAreTrustedAndTheRestUntapped() {
        let installed = [
            InstalledPackageOrigin(kind: .cask, name: "codexbar", tap: "steipete/tap"),
            InstalledPackageOrigin(kind: .formula, name: "peekaboo", tap: "steipete/tap"),
            InstalledPackageOrigin(kind: .formula, name: "git", tap: "homebrew/core"),
        ]

        let remedies = TapTrustPlanner.remedies(forUntrustedTaps: Self.listed, installed: installed)

        #expect(remedies == [
            TapTrustRemedy(kind: .trustInstalledCasks, arguments: ["trust", "--cask", "--", "steipete/tap/codexbar"]),
            TapTrustRemedy(kind: .trustInstalledFormulae, arguments: ["trust", "--formula", "--", "steipete/tap/peekaboo"]),
            TapTrustRemedy(kind: .untapUnused, arguments: ["untap", "--", "manaflow-ai/cmux"]),
        ])
    }

    @Test func givenNoUntrustedTapsWhenPlanningThenNothingIsOffered() {
        let installed = [InstalledPackageOrigin(kind: .cask, name: "codexbar", tap: "steipete/tap")]

        #expect(TapTrustPlanner.remedies(forUntrustedTaps: [], installed: installed).isEmpty)
    }

    /// The notice shows the exact command a button runs, `--` fence included.
    @Test func givenARemedyWhenShownThenItsCommandLineIsTheCommandThatRuns() {
        let remedy = TapTrustRemedy(kind: .untapUnused, arguments: ["untap", "--", "steipete/tap"])

        #expect(remedy.commandLine == "brew untap -- steipete/tap")
    }
}
