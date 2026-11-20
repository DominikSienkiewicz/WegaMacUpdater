import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Scan and migration copy") @MainActor
struct ScanAndMigrationCopyTests {
    static let jargon = ["SHA256", "CFBundleShortVersion", "_MASReceipt", "brew outdated", "Pulę pamięci",
                         "plist", "Sparkle", "Cellar", "Bundle ID"]

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The literal list between `marker` and the first `]` after it.
    private func list(_ file: String, after marker: String) throws -> Substring {
        let text = try source(file)
        let start = try #require(text.range(of: marker)).upperBound
        return text[start..<(try #require(text.range(of: "]", range: start..<text.endIndex))).lowerBound]
    }

    @Test func wegasScanLinesSpeakHerLanguageNotACompilers() throws {
        let lists = [try list("Sources/MacUpdater/ScanBusyOverlay.swift", after: "static let scanThoughts: [String] = ["),
                     try list("Sources/MacUpdater/SniffingScene.swift", after: "static let defaultThoughts: [String] = ["),
                     try list("Sources/MacUpdater/MigrationView.swift", after: "thoughts: [")]
        for (index, lines) in lists.enumerated() {
            for term in Self.jargon { #expect(!lines.contains(term), "list \(index): \(term)") }
        }
        let all = lists.joined()
        for line in ["Sprawdzam, czy aplikacje same się aktualizują…", "Porównuję wersje…",
                     "Zaglądam do środka aplikacji…", "Węszę w App Store…", "Hau, ta wersja pachnie świeżo!"] {
            #expect(all.contains("tr(\"\(line)\")"), "\(line)")
        }
        withLanguage(.en) {
            #expect(tr("Porównuję wersje…") == "Comparing versions…")
            #expect(tr("Hau, ta wersja pachnie świeżo!") == "Woof, this version smells fresh!")
        }
    }

    @Test func thePhaseCommandMovesToTheTooltip() throws {
        let scene = try source("Sources/MacUpdater/ScanBusyOverlay.swift")
        let body = try #require(scene.range(of: "struct ScanProgressScene: View"))
        #expect(!scene[body.upperBound...].prefix(1200).contains("Text(phaseLabel)"))
        #expect(scene[body.upperBound...].prefix(1200).contains(".help(presentation.phaseLabel ?? \"\")"))
    }

    @Test func theMigrationSheetNamesTheBackupAndTheWayBack() throws {
        let view = try source("Sources/MacUpdater/MigrationView.swift")
        let sheet = view[try #require(view.range(of: "private struct MigrationConfirmSheet")).lowerBound...]
        #expect(sheet.contains("trf(\"Przenieść %@ do Homebrew?\", app.name)"))
        #expect(sheet.contains("Button(tr(\"Przenieś\"))"))
        #expect(!sheet.contains("tr(\"Migruj\")"))
        #expect(!sheet.contains("Homebrew pobierze najnowszą wersję"))
        #expect(sheet.contains(".keyboardShortcut(.cancelAction)"))
        withLanguage(.en) {
            #expect(trf("Przenieść %@ do Homebrew?", "Slack") == "Move Slack to Homebrew?")
            #expect(tr("Przenieś") == "Move")
        }
    }

    @Test func theNoRunawaysLineHasNoTypo() throws {
        #expect(try source("Sources/MacUpdater/MigrationStore.swift")
            .contains("tr(\"Wszystko w porządku. Wega nie znalazła uciekinierów.\")"))
    }
}
