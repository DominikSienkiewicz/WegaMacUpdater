import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-34 part 1 and UXP-35 part 1 — Wega says how to remove herself, and the Updates list says
/// where to look for an app it does not show.
@Suite("First steps of the bigger bets") @MainActor
struct FirstStepsTests {
    private func source(_ path: String, file: String = #filePath) throws -> String {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func wegaSaysHowToRemoveHerselfAndTheGuideHasEveryStep() throws {
        #expect(AppEndpoints.shared.uninstallGuideURL.absoluteString.hasSuffix("/blob/main/USER_GUIDE.md#uninstalling-wega"))
        let uninstall = try source("Sources/MacUpdater/UninstallView.swift")
        #expect(uninstall.contains("if protection == .wegaItself {"))
        #expect(uninstall.contains("Link(tr(\"Jak usunąć Wegę i jej pomocnika\"), destination: AppEndpoints.shared.uninstallGuideURL)"))
        #expect(try source("Sources/MacUpdater/TrustSettingsCard.swift").contains("AppEndpoints.shared.uninstallGuideURL"))
        withLanguage(.en) { #expect(tr("Jak usunąć Wegę i jej pomocnika") == "How to remove Wega and its helper") }
        let guide = try source("USER_GUIDE.md")
        let section = try #require(guide.range(of: "### Uninstalling Wega")).upperBound
        let body = guide[section...].prefix(4000)
        for step in ["Launch at login", "Remove Helper", "pam_tid.so", "/etc/pam.d/sudo_local", "Quit Wega",
                     "update-operations", "~/Library/Logs/WegaMacUpdater", "/Library/Application Support/WegaMacUpdater/Authorization",
                     "com.wega.WegaMacUpdater"] {
            #expect(body.contains(step), "\(step)")
        }
    }

    @Test func theListSaysWhereToLookForAMissingApp() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let start = try #require(view.range(of: "private var listColumn: some View")).upperBound
        let end = try #require(view.range(of: "/// F2 — \"show me exactly what you will do\"", range: start..<view.endIndex)).lowerBound
        #expect(view[start..<end].components(separatedBy: "MissingAppHint(onOpenInventory: { onNavigate?(.inventory) })").count == 4,
                "under the rows and under both empty states")
        withLanguage(.en) {
            #expect(tr("Nie widzisz aplikacji? Brak na liście nie znaczy, że jest aktualna — sprawdź jej status w Spisie")
                    == "Can't see an app? Missing from the list doesn't mean up to date — check its status in Inventory")
        }
    }
}
