import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Uninstall list — protected rows")
struct UninstallProtectedRowsTests {
    private func app(_ name: String) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name)",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }

    @Test func changingSearchKeepsTheSelectionForConfirmation() throws {
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacUpdater/UninstallView.swift"), encoding: .utf8)
        #expect(!view.contains("selected.formIntersection(filtered.map"))
        #expect(view.contains("UninstallSelection.targets(filtered: appRows"))
        #expect(view.contains("UninstallSelectionBasket("))
    }

    @Test func togglingVisibleChangesOnlyUnprotectedSearchResults() {
        let slack = app("Slack"), zoom = app("Zoom"), protected = app("System")
        let protections = [protected.id: UninstallProtection.systemApplication]
        let visible = [zoom, protected]
        let both = UninstallSelection.togglingVisible(visible, in: [slack.id], protections: protections)
        #expect(both == [slack.id, zoom.id])
        #expect(UninstallSelection.togglingVisible(visible, in: both, protections: protections) == [slack.id])
        #expect(UninstallSelection.togglingVisible([], in: both, protections: protections) == both)
        let basket = UninstallSelection.targets(filtered: [zoom, slack, protected], selected: both, protections: protections)
        #expect(basket.map(\.id) == [zoom.id, slack.id])
    }

    @Test func selectAllSkipsProtectedRows() {
        let apps = [app("Alpha"), app("Safari"), app("Gamma")]
        let protections = [apps[1].id: UninstallProtection.systemApplication]

        let selection = UninstallSelection.selectAll(filtered: apps, protections: protections)

        #expect(selection == [apps[0].id, apps[2].id])
    }

    @Test func targetsNeverContainProtected() {
        let apps = [app("Alpha"), app("Wega")]
        let protections = [apps[1].id: UninstallProtection.wegaItself]

        let targets = UninstallSelection.targets(
            filtered: apps,
            selected: Set(apps.map(\.id)),
            protections: protections
        )

        #expect(targets.map(\.id) == [apps[0].id])
    }

    @Test func contextMenuHasNoToggleForProtected() {
        let items = AppRowContextMenu.items(isSelected: false, canToggle: false)

        #expect(!items.contains { $0.action == .toggleSelection })
        #expect(items.map(\.action) == [.revealInFinder, .copyPath])
    }

    @Test func contextMenuKeepsToggleByDefault() {
        #expect(AppRowContextMenu.items(isSelected: false).first?.action == .toggleSelection)
    }

    @Test func reasonsAreLocalized() {
        let reasons: [(UninstallProtection, String)] = [
            (.wegaItself, "To jest Wega — nie usuwa samej siebie"),
            (.systemApplication, "Aplikacja systemowa macOS — chroniona przez system"),
        ]
        for (protection, base) in reasons {
            #expect(UninstallProtectionPresentation.protectionReason(protection) == base)
            #expect(Translations.en[base] != nil)
        }
        #expect(Translations.en["To tylko dowiązanie do %@"] != nil)
        #expect(
            UninstallProtectionPresentation.protectionReason(.symlink(destination: "/Applications/X.app"))
                == "To tylko dowiązanie do /Applications/X.app"
        )
    }

    @Test func accessibilityLabelAppendsReason() {
        let label = selectionAccessibilityLabel(
            for: app("Safari"),
            showsLocation: false,
            protectionReason: "Powód"
        )
        #expect(label == "Safari, Powód")
    }

    @Test func selectAllSymbolCountsOnlySelectableRows() {
        let apps = [app("Alpha"), app("Safari")]
        let protections = [apps[1].id: UninstallProtection.systemApplication]
        let selected = UninstallSelection.selectAll(filtered: apps, protections: protections)

        #expect(
            UninstallSelection.selectAllSymbol(filtered: apps, selected: selected, protections: protections)
                == "checkmark.square.fill"
        )
        #expect(
            UninstallSelection.selectAllSymbol(filtered: apps, selected: [], protections: protections)
                == "square"
        )
    }
}
