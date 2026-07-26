import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

/// UX-11d — the uninstall list's rows gained a right-click context menu. The menu's
/// contents and wording are modelled as data (`AppRowContextMenu`) so they can be
/// asserted here without a running view.
final class AppRowContextMenuTests: XCTestCase {
    func testUnselectedRowOffersRevealCopyAndSelectForRemoval() {
        let items = AppRowContextMenu.items(isSelected: false)

        XCTAssertEqual(
            items.map(\.action),
            [.toggleSelection, .revealInFinder, .copyPath]
        )
        XCTAssertEqual(items[0].title, tr("Zaznacz do odinstalowania"))
        XCTAssertEqual(items[1].title, tr("Pokaż w Finderze"))
        XCTAssertEqual(items[2].title, tr("Kopiuj ścieżkę"))
    }

    func testSelectedRowOffersDeselectInsteadOfSelect() {
        let selected = AppRowContextMenu.items(isSelected: true)
        let unselected = AppRowContextMenu.items(isSelected: false)

        // Only the toggle item's wording flips; the rest of the menu is stable.
        XCTAssertEqual(selected.map(\.action), unselected.map(\.action))
        XCTAssertEqual(selected[0].title, tr("Odznacz"))
        XCTAssertNotEqual(selected[0].title, unselected[0].title)
        XCTAssertEqual(Array(selected.dropFirst()), Array(unselected.dropFirst()))
    }

    func testEveryItemCarriesASystemImage() {
        for item in AppRowContextMenu.items(isSelected: false) {
            XCTAssertFalse(item.systemImage.isEmpty)
        }
    }

    func testPathToCopyIsTheInstallationFilesystemPath() {
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Firefox.app"),
            name: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )

        XCTAssertEqual(AppRowContextMenu.pathToCopy(for: app), "/Applications/Firefox.app")
    }
}
