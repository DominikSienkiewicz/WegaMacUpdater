import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

/// LT-01 — „Cofnij aktualizacje” moved off the Updates list into its own destination.
///
/// Two things had to become true for that move to be safe, and neither is visible from
/// reading a view body: the sidebar badge has to count what the destination will show
/// (otherwise the only entry point to undo is a row the user has no reason to click), and
/// the new destination has to carry an accessibility reading order like every other one.
@MainActor
final class RollbackDestinationTests: XCTestCase {

    private enum StubError: Error {
        case unexpected([String])
    }

    /// Lets a test change what the journal reports between two refreshes.
    private final class RetainedSnapshots: @unchecked Sendable {
        var items: [UndoableUpdate]
        init(_ items: [UndoableUpdate]) { self.items = items }
    }

    /// The badge is fed by a sink, not by observing `ScanStore` from the window root, so the
    /// wiring is only correct if `refreshUndoableUpdates()` actually pushes through it. This
    /// is the one call every change to `undoableUpdates` goes through.
    func testRefreshingUndoableUpdatesReportsTheBadgeCount() {
        let undoable = UndoableUpdate(
            operationID: UUID(),
            token: "badge-cask",
            appPath: "/Applications/Badge.app",
            restoredVersion: "1.0",
            updatedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )
        let runner = ScanStoreRuntimeProcessRunner { request in
            throw StubError.unexpected(request.arguments)
        }
        let retained = RetainedSnapshots([undoable])
        let harness = makeScanStoreRuntimeHarness(runner: runner, undoableUpdates: { retained.items })

        var reported: [Int] = []
        harness.store.bind(ScanSinks(undoableCount: { reported.append($0) }))

        harness.store.refreshUndoableUpdates()
        XCTAssertEqual(reported, [1])

        // The retention sweep dropping the last snapshot has to clear the badge, not leave a
        // stale "1" pointing at an empty destination.
        retained.items = []
        harness.store.refreshUndoableUpdates()
        XCTAssertEqual(reported, [1, 0])
    }

    /// `SidebarFocusPolicy` returns priority `0` for a selection missing from its ordering —
    /// silently, so a new destination reads last with no failure anywhere. The ordering is
    /// derived from `SidebarSelection.allCases` to make that impossible; this pins the
    /// derivation rather than the current spelling of the list.
    func testEverySidebarSelectionHasAReadingPriority() {
        for selection in SidebarSelection.allCases {
            XCTAssertGreaterThan(
                SidebarFocusPolicy.accessibilityPriority(for: selection),
                0,
                "\(selection.rawValue) has no accessibility reading priority"
            )
        }
    }

    /// Undo is a destination of its own now: it must survive the `@AppStorage` round trip the
    /// window's selection is persisted through, and it must not be mistaken for a filter of
    /// the Updates list.
    func testRollbackIsAPersistableDestinationAndNotAnUpdatesFilter() {
        XCTAssertEqual(SidebarSelection(rawValue: SidebarSelection.rollback.rawValue), .rollback)
        XCTAssertNil(SidebarSelection.rollback.filter)
        XCTAssertEqual(SidebarSelection.rollback.tab, .rollback)
        XCTAssertEqual(SidebarSelection.forTab(.rollback), .rollback)
    }
}
