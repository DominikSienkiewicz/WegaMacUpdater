import XCTest
@testable import WegaMacUpdater
import MacUpdaterCore

/// UX-10 — keyboard shortcuts and menu items. The `.commands` wiring itself is a SwiftUI
/// scene and not unit-testable, so these tests pin the two pieces of logic behind it: the
/// ⌘1…⌘6 destination mapping, and the ⌘F focus-request bus.
@MainActor
final class MenuCommandsTests: XCTestCase {

    /// ⌘1…⌘6 must map to the coarse sidebar sections, top to bottom, each exactly once. The
    /// Updates section opens on its unfiltered list.
    ///
    /// The count grew from five when „Cofnij aktualizacje” became a destination of its own;
    /// what this pins has not changed. The numbers follow the sidebar, so a new section is
    /// expected to take its place in the middle and push the ones below it down a digit —
    /// the failure this guards against is a *visible* destination that no number reaches.
    func testNumberedDestinationsCoverEverySectionInSidebarOrder() {
        let destinations = WegaMenuNavigation.numberedDestinations

        XCTAssertEqual(
            destinations.map(\.tab),
            [.update, .migration, .inventory, .rollback, .uninstall, .cleanup, .logs],
            "The numbered destinations must follow the sidebar's top-to-bottom order"
        )
        XCTAssertEqual(
            Set(destinations.map(\.tab)),
            Set(SidebarSelection.allCases.map(\.tab)),
            "Every sidebar section must be reachable by a number key"
        )
        XCTAssertEqual(destinations.first, .updates(.all), "⌘1 opens the unfiltered Updates list")
        XCTAssertEqual(
            Set(destinations.map(\.tab)).count,
            destinations.count,
            "No section is reachable by two different number keys"
        )
    }

    /// ⌘F leaves a single pending focus request that the inventory consumes exactly once —
    /// so navigating to the inventory (which mounts its search field afresh) still focuses it,
    /// without re-stealing focus on the next unrelated appearance.
    func testInventorySearchFocusRequestIsConsumedOnce() {
        let center = WegaCommandCenter()

        XCTAssertFalse(center.consumePendingInventorySearchFocus(), "no request has been made yet")

        center.requestInventorySearchFocus()
        XCTAssertTrue(center.consumePendingInventorySearchFocus(), "the pending ⌘F is consumed")
        XCTAssertFalse(center.consumePendingInventorySearchFocus(), "it is not consumed twice")

        center.requestInventorySearchFocus()
        XCTAssertTrue(center.consumePendingInventorySearchFocus(), "a fresh ⌘F is available again")
    }

    /// UXP-23 — ⇧⌘F keeps asking for the inventory's field, now as one screen of the per-screen
    /// bus that ⌘F uses: a request for one screen is never consumed by another.
    func testEachScreenConsumesOnlyItsOwnSearchFocusRequest() {
        let center = WegaCommandCenter()

        center.requestInventorySearchFocus()
        XCTAssertEqual(center.searchFocusRequests[.inventory], 1)
        XCTAssertFalse(center.consumePendingSearchFocus(on: .logs), "a request for the inventory is not the logs'")
        XCTAssertTrue(center.consumePendingSearchFocus(on: .inventory), "the inventory consumes it through the same bus")
        XCTAssertFalse(center.consumePendingInventorySearchFocus(), "and only once")

        center.requestSearchFocus(on: .uninstall)
        center.requestSearchFocus(on: .logs)
        XCTAssertTrue(center.consumePendingSearchFocus(on: .uninstall))
        XCTAssertTrue(center.consumePendingSearchFocus(on: .logs))
        XCTAssertFalse(center.consumePendingInventorySearchFocus(), "neither request was the inventory's")
    }

    /// next10 wired ⌘. to stop a running update after the installs already started. UXP-23 adds
    /// cancelling a scan to the same item; stopping the update keeps its gate and its call.
    func testCommandPeriodStillStopsTheUpdateItsWayFirst() throws {
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        XCTAssertTrue(detail.contains(
            ".focusedSceneValue(\\.stopUpdateAction, WegaMenuAction(\n                isEnabled: scan.updating && !scan.updateInterruption.isRequested,\n                run: { scan.cancelUpdate() }"
        ))
        let commands = try source("Sources/MacUpdater/WegaCommands.swift")
        XCTAssertTrue(commands.contains("let cancelTarget = WegaMenuAction.firstEnabled(stopUpdate, cancelScan)"),
                      "a stop the run can take wins over a scan to cancel")
        XCTAssertTrue(commands.contains("Button(CancelCommandCopy.title(stopsUpdate: stopUpdate?.isEnabled == true)) { cancelTarget?.run() }"))
        XCTAssertEqual(commands.components(separatedBy: ".keyboardShortcut(\".\", modifiers: .command)").count, 2,
                       "one ⌘. item, never two")
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        XCTAssertTrue(view.contains("isEnabled: scan.scanTask != nil && !scan.updating,\n                run: { scan.cancelScan() }"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
