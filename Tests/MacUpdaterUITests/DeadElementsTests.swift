import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Dead elements") @MainActor
struct DeadElementsTests {
    @Test func onlyScreensThatScanForUpdatesOfferTheScanButton() {
        let shown: Set<SidebarTab> = [.update, .migration, .rollback]
        for tab in [SidebarTab.update, .rollback, .uninstall, .cleanup, .migration, .inventory, .logs] {
            #expect(tab.showsScanControl == shown.contains(tab), "\(tab)")
        }
    }

    @Test func aHiddenScanButtonKeepsItsSlotButTakesNoFocus() throws {
        let control = try source("Sources/MacUpdater/ScanControl.swift")
        for literal in [".opacity(isShown ? 1 : 0)", ".disabled(!isShown)", ".accessibilityHidden(!isShown)", ".frame(width: 135)"] {
            #expect(control.contains(literal), "\(literal)")
        }
        #expect(try source("Sources/MacUpdater/ContentView.swift")
            .contains("ScanControl(namespace: glassNamespace, isShown: selection.tab.showsScanControl)"))
        #expect(try source("Sources/MacUpdater/UpdateView.swift").contains(".focusedSceneValue(\\.startCheckAction"),
                "⌘R stays on every screen")
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
