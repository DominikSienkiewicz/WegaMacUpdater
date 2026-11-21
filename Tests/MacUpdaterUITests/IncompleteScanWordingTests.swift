import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// The owner's wording (2026-11-21): every place that shows an incomplete scan says „skan niepełny”,
/// the band's words — Inventory, the menu bar and VoiceOver included.
@Suite("Incomplete scan wording")
struct IncompleteScanWordingTests {
    private let now = Date()

    private var app: ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                        bundleIdentifier: nil, version: "1", installDate: nil, updateDate: nil,
                        isManagedByBrew: false, caskToken: nil)
    }

    private func presentation(_ sources: [InstallationSourceCheck]) -> InventoryCheckPresentation {
        InventoryCheckPresentation(app: app, check: InstallationCheck(app: app, sources: sources, checkedAt: now),
                                   policies: [:], now: now)
    }

    @Test func inventorySaysTheScanIsIncomplete() {
        let failed = presentation([.init(source: "Sparkle", outcome: .failed)])
        let partial = presentation([.init(source: "Sparkle", outcome: .outdated, availableVersion: "2"),
                                    .init(source: "GitHub", outcome: .failed)])
        #expect(failed.status == InstallationCheckStatus.failed)
        #expect(partial.status == InstallationCheckStatus.updateAvailable)
        withLanguage(.pl) {
            #expect(failed.title == "Skan niepełny")
            #expect(partial.title == "Aktualizacja; skan niepełny")
        }
        withLanguage(.en) {
            #expect(failed.title == "Check incomplete")
            #expect(partial.title == "Update available; check incomplete")
        }
    }

    @Test func theMenuBarAndVoiceOverSayTheScanIsIncomplete() {
        let menu = MenuBarStatusPresentation(count: 3, isChecking: false, failed: false, incomplete: true, lastCheck: now)
        withLanguage(.pl) {
            #expect(menu.statusText == trp("%@ aktualizacji dostępnych", 3) + " · skan niepełny")
            #expect(AnnouncementCopy.scanFinished(updates: 0, complete: false) == "Skan zakończony: 0 aktualizacji. Skan niepełny.")
        }
        withLanguage(.en) {
            #expect(menu.statusText.hasSuffix(" · check incomplete"))
            #expect(AnnouncementCopy.scanFinished(updates: 0, complete: false).hasSuffix(" Check incomplete."))
        }
    }
}
