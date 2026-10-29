import Foundation
import Testing
@testable import MacUpdaterCore

/// Homebrew 7 refuses to load anything from a third-party tap the user has not trusted, and
/// says so in the output of most brew commands. Wega shows that output in its brew log, so
/// the log is where the warning has to be recognised — including in the batch lane, where
/// every line carries the `[token] ` prefix of the package it came from.
@Suite("Tap trust — recognising Homebrew's warning in the brew log")
struct TapTrustWarningTests {
    /// The warning exactly as it reached the user's brew log.
    static let warning = [
        "Warning: The following taps are not trusted:",
        "  manaflow-ai/cmux",
        "  steipete/tap",
        "",
        "Homebrew is currently ignoring formulae, casks and commands",
        "from these taps because tap trust is required.",
        "Untap them with:",
        "  brew untap manaflow-ai/cmux steipete/tap",
        "Trust specific formulae, casks and commands with:",
        "  brew trust --formula <user>/<tap>/<formula>",
        "  brew trust --cask <user>/<tap>/<cask>",
        "  brew trust --command <user>/<tap>/<command>",
        "Whole-tap trust is broader and includes all current and future formulae,",
        "casks and commands from the listed taps. Trust whole taps with:",
        "  brew trust manaflow-ai/cmux steipete/tap",
        "For more information, see:",
        "  https://docs.brew.sh/Tap-Trust",
    ]

    @Test func givenTheWarningWhenTheLogIsReadThenItNamesTheListedTaps() {
        let log = ["$ brew upgrade --cask -- zoom"] + Self.warning + ["==> Upgrading zoom"]

        #expect(TapTrustWarning.untrustedTaps(in: log) == ["manaflow-ai/cmux", "steipete/tap"])
    }

    @Test func givenBatchLanePrefixesWhenTheLogIsReadThenThePrefixDoesNotHideTheWarning() {
        let log = UpgradeLogPrefix.lines(Self.warning, from: "zoom")

        #expect(TapTrustWarning.untrustedTaps(in: log) == ["manaflow-ai/cmux", "steipete/tap"])
    }

    @Test func givenTheWarningOncePerPackageWhenTheLogIsReadThenEachTapIsNamedOnce() {
        let log = UpgradeLogPrefix.lines(Self.warning, from: "zoom")
            + UpgradeLogPrefix.lines(Self.warning, from: "slack")

        #expect(TapTrustWarning.untrustedTaps(in: log) == ["manaflow-ai/cmux", "steipete/tap"])
    }

    @Test func givenNoWarningWhenTheLogMentionsUntapThenNoTapIsNamed() {
        let log = [
            "$ brew untap -- manaflow-ai/cmux",
            "Untapping manaflow-ai/cmux...",
            "You have the following deprecated, official taps tapped:",
            "Untap them with `brew untap`.",
            "  brew untap homebrew/cask-fonts",
        ]

        #expect(TapTrustWarning.untrustedTaps(in: log).isEmpty)
    }

    /// The names end up as arguments of a command the user runs with one click, so anything
    /// in the remedy lines that is not shaped like a tap name is dropped rather than passed on.
    @Test func givenARemedyLineWithAnOptionWhenTheLogIsReadThenOnlyTapShapedNamesSurvive() {
        let log = [
            "from these taps because tap trust is required.",
            "Untap them with:",
            "  brew untap --force evil/tap ../../etc a/b/c",
        ]

        #expect(TapTrustWarning.untrustedTaps(in: log) == ["evil/tap"])
    }
}
