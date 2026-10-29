import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// The notice in the brew log panel. Trusting or removing a tap changes the user's Homebrew
/// configuration, so every row says what its button does in words and shows the exact
/// command it runs — the same vector `ScanStore.runTapTrustRemedy` hands to brew.
@Suite("Tap trust — the notice in the brew log panel")
@MainActor
struct TapTrustNoticeTests {
    @Test func givenAnUntapRemedyWhenPresentedThenTheRowNamesTheUnusedTapsAndItsExactCommand() {
        let remedy = TapTrustRemedy(kind: .untapUnused, arguments: ["untap", "--", "manaflow-ai/cmux", "steipete/tap"])

        let row = TapTrustRemedyPresentation(remedy)

        #expect(row.buttonTitle == tr("Odepnij nieużywane tapy"))
        #expect(row.explanation == tr("Nic zainstalowanego nie pochodzi z tych tapów."))
        #expect(row.command == "brew untap -- manaflow-ai/cmux steipete/tap")
    }

    @Test func givenTrustRemediesWhenPresentedThenEachRowTrustsOnlyTheInstalledItems() {
        let casks = TapTrustRemedyPresentation(
            TapTrustRemedy(kind: .trustInstalledCasks, arguments: ["trust", "--cask", "--", "steipete/tap/codexbar"])
        )
        let formulae = TapTrustRemedyPresentation(
            TapTrustRemedy(kind: .trustInstalledFormulae, arguments: ["trust", "--formula", "--", "steipete/tap/peekaboo"])
        )

        #expect(casks.buttonTitle == tr("Zaufaj zainstalowanym caskom"))
        #expect(casks.explanation == tr("Tylko te zainstalowane caski — nie cały tap."))
        #expect(casks.command == "brew trust --cask -- steipete/tap/codexbar")
        #expect(formulae.buttonTitle == tr("Zaufaj zainstalowanym formułom"))
        #expect(formulae.explanation == tr("Tylko te zainstalowane formuły — nie cały tap."))
        #expect(formulae.command == "brew trust --formula -- steipete/tap/peekaboo")
    }

    /// Buttons appear on the Updates screen's log only. The run overlay shows the same panel
    /// mid-update, where a click would only meet the busy mutex — so it offers none.
    @Test func givenTheTwoBrewLogPanelsWhenWiredThenOnlyTheIdleOneOffersTapTrustButtons() throws {
        let updateView = try Self.source("UpdateView.swift")
        let runOverlay = try Self.source("UpdateRunOverlay.swift")

        #expect(updateView.contains("BrewLogPanel(lines: scan.brewLog, tapTrust: scan.tapTrustActions)"))
        #expect(runOverlay.contains("BrewLogPanel(lines: logLines, onClose: onHideLog)"))
    }

    private static func source(_ fileName: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/MacUpdater/\(fileName)"), encoding: .utf8)
    }
}
