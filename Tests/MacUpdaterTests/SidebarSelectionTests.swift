import XCTest
@testable import MacUpdaterCore

/// `NavigationSplitView` selects on a single value, so the sidebar's two axes — which tab is
/// active, and which category the Updates list is filtered to — collapse into one enum. These
/// tests pin the three things that can break silently: the string round trip that `@AppStorage`
/// depends on, the filter projection the Updates list reads, and the one-shot migration from
/// the pre-macOS-26 `wega.activeTab` key.
final class SidebarSelectionTests: XCTestCase {

    private let everyCase: [SidebarSelection] = [
        .updates(.all), .updates(.apps), .updates(.cli), .updates(.security),
        .migration, .inventory, .uninstall, .logs
    ]

    func testRawValueRoundTripsForEveryCase() {
        for selection in everyCase {
            XCTAssertEqual(
                SidebarSelection(rawValue: selection.rawValue),
                selection,
                "round trip failed for \(selection.rawValue)"
            )
        }
    }

    func testRawValuesAreDistinct() {
        let raws = everyCase.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, everyCase.count, "two cases share a raw value: \(raws)")
    }

    func testUnknownRawValueIsRejected() {
        XCTAssertNil(SidebarSelection(rawValue: "updates"))
        XCTAssertNil(SidebarSelection(rawValue: "updates.everything"))
        XCTAssertNil(SidebarSelection(rawValue: ""))
    }

    func testFilterIsPresentOnlyForUpdates() {
        XCTAssertEqual(SidebarSelection.updates(.security).filter, .security)
        XCTAssertEqual(SidebarSelection.updates(.all).filter, .all)
        XCTAssertNil(SidebarSelection.logs.filter)
        XCTAssertNil(SidebarSelection.migration.filter)
        XCTAssertNil(SidebarSelection.inventory.filter)
        XCTAssertNil(SidebarSelection.uninstall.filter)
    }

    func testDefaultIsAllUpdates() {
        XCTAssertEqual(SidebarSelection.default, .updates(.all))
    }

    /// The old key stored only the tab, never the filter, so `update` restores the `.all` list.
    func testLegacyTabMigration() {
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "update"), .updates(.all))
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "uninstall"), .uninstall)
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "migration"), .migration)
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "inventory"), .inventory)
        XCTAssertEqual(SidebarSelection.migrating(legacyTab: "logs"), .logs)
    }

    func testLegacyTabMigrationRejectsUnknownAndNil() {
        XCTAssertNil(SidebarSelection.migrating(legacyTab: "nope"))
        XCTAssertNil(SidebarSelection.migrating(legacyTab: ""))
        XCTAssertNil(SidebarSelection.migrating(legacyTab: nil))
    }
}
