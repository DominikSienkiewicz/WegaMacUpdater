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
        #expect(AppEndpoints.shared.touchIDGuideURL.absoluteString.hasSuffix("/blob/main/USER_GUIDE.md#turning-off-touch-id-for-sudo"))
        let card = try source("Sources/MacUpdater/TrustSettingsCard.swift")
        let touchID = try #require(card.range(of: "if permission.kind == .touchID {")).upperBound
        #expect(card[touchID...].prefix(260).contains("Link(tr(\"Jak wyłączyć Touch ID dla sudo\"), destination: AppEndpoints.shared.touchIDGuideURL)"))
        withLanguage(.en) { #expect(tr("Jak wyłączyć Touch ID dla sudo") == "How to turn off Touch ID for sudo") }
        withLanguage(.en) { #expect(tr("Jak usunąć Wegę i jej pomocnika") == "How to remove Wega and its helper") }
        let guide = try source("USER_GUIDE.md")
        let section = try #require(guide.range(of: "### Uninstalling Wega")).upperBound
        let body = guide[section...].prefix(8000)
        #expect(body.contains("#### Turning off Touch ID for sudo"))
        let pamLine = "auth       sufficient     pam_tid.so"
        #expect(try source("Sources/WegaHelperKit/TouchIDSudoConfigurator.swift").contains("pamDirective = \"\(pamLine)\""))
        #expect(body.contains("`\(pamLine)`"), "the PAM line is quoted byte for byte")
        for step in ["sudo -s", "sudo_local.bak", "sudo -k; sudo true", "#auth", "cp /etc/pam.d/sudo_local.bak /etc/pam.d/sudo_local",
                     "sudo rm -r \"/Library/Application Support/WegaMacUpdater\"",
                     "sudo rm -r \"/Library/Application Support/com.wega.WegaMacUpdater\"",
                     "sudo rm -r \"/var/db/com.wega.WegaMacUpdater\"", "sudo pkgutil --forget com.wega.WegaMacUpdater",
                     "~/Library/Caches/WegaMacUpdater", "HTTPStorages/com.wega.WegaMacUpdater",
                     "com.wega.WegaMacUpdater.github", "github-pat"] {
            #expect(body.contains(step), "\(step)")
        }
        for step in ["Launch at login", "Remove Helper", "pam_tid.so", "/etc/pam.d/sudo_local", "Quit Wega",
                     "update-operations", "~/Library/Logs/WegaMacUpdater",
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
        let hint = try source("Sources/MacUpdater/MissingAppHint.swift")
        #expect(hint.contains("Button(action: onOpenInventory) {"))
        #expect(hint.contains("Label(tr(\"Nie widzisz aplikacji? Brak na liście nie znaczy, że jest aktualna — sprawdź jej status w Spisie\"),"))
        #expect(hint.contains("systemImage: \"magnifyingglass\")"))
        withLanguage(.en) {
            #expect(tr("Nie widzisz aplikacji? Brak na liście nie znaczy, że jest aktualna — sprawdź jej status w Spisie")
                    == "Can't see an app? Missing from the list doesn't mean up to date — check its status in Inventory")
        }
    }
}
