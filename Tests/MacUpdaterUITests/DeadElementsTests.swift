import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Dead elements") @MainActor
struct DeadElementsTests {
    /// The scan button lives in the Updates content (owner, 2026-11-22): not in the toolbar, not on
    /// Do Homebrew (its own „Skanuj /Applications”) and not on Cofnij (it re-reads its list).
    @Test func onlyUpdatesOffersTheScanButton() throws {
        #expect(try source("Sources/MacUpdater/UpdateView.swift").contains("ScanRoundButton("))
        #expect(!(try source("Sources/MacUpdater/ContentView.swift")).contains("ScanControl("))
        for screen in ["MigrationView", "RollbackView", "UninstallView", "CleanupView", "InventoryView", "LogsView"] {
            #expect(!(try source("Sources/MacUpdater/\(screen).swift")).contains("ScanRoundButton"), "\(screen)")
        }
    }

    @Test func theShortcutsStayOnEveryScreen() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains(".focusedSceneValue(\\.startCheckAction"), "⌘R stays on every screen")
        #expect(view.contains(".focusedSceneValue(\\.cancelScanAction"), "and so does ⌘.")
    }

    @Test func theNpmCardIsACounterNotAButton() throws {
        let view = try source("Sources/MacUpdater/InventoryView.swift")
        let npm = try #require(view.range(of: "InventoryStatCard(label: \"npm -g\""))
        #expect(view[npm.upperBound...].prefix(240).contains("onTap: nil"))
        #expect(view.contains("trf(\"Globalne pakiety npm: %@\""))
        #expect(!view.contains("tapping is a deliberate no-op"))
        withLanguage(.en) { #expect(trf("Globalne pakiety npm: %@", "3") == "Global npm packages: 3") }
    }

    @Test func deadCodeAndKeysAreGone() throws {
        #expect(!(try source("Sources/MacUpdater/WegaViews.swift")).contains("struct HelperChip"))
        #expect(!Translations.en.keys.contains { $0.hasPrefix("Wega potrzebuje Homebrew") || $0.hasPrefix("brew · helper") })
        let uninstall = try source("Sources/MacUpdater/UninstallView.swift")
        #expect(!uninstall.contains("Text(tr(\"Odinstaluj aplikacje\"))"), "the window title already says it")
        let effects = try #require(uninstall.range(of: "Brew casks → brew uninstall"))
        // The effects line's own modifiers: up to the `Spacer()` that follows it in the header.
        let effectsEnd = try #require(uninstall.range(of: "Spacer()", range: effects.upperBound..<uninstall.endIndex))
        #expect(uninstall[effects.upperBound..<effectsEnd.lowerBound].contains(".foregroundStyle(.secondary)"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
