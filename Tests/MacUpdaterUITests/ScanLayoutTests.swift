import SwiftUI
import XCTest
@testable import WegaMacUpdater

/// A scan changes several pieces of window chrome at once. The sidebar must keep the same
/// geometry throughout that transition; changing its safe-area padding makes NSSplitView
/// repeatedly solve constraints until AppKit aborts the process.
///
/// The toolbar's scan control and its width checks went with the control (owner, 2026-11-22):
/// the scan button is now `ScanRoundButton` in the content, one size in every state
/// (`ScanRoundButtonTests.theButtonIsOneSizeInEveryState`), and the toolbar no longer changes.
final class ScanLayoutTests: XCTestCase {
    @MainActor
    func testSidebarKeepsItsWidthWhenScanActivityChanges() {
        let idleWidth = fittingWidth(for: .idle)
        let scanningWidth = fittingWidth(for: .scanning)

        XCTAssertEqual(scanningWidth, idleWidth, accuracy: 0.5)
    }

    @MainActor
    private func fittingWidth(for activity: UpdateActivity) -> CGFloat {
        let view = SidebarList(
            selection: .constant(.initial),
            appsBadge: 0,
            cliBadge: 0,
            securityBadge: 0,
            logsErrorBadge: 0,
            rollbackBadge: 0,
            updateActivity: activity,
            wegaState: .forTab(.update),
            lastCheck: nil,
            quip: nil
        )
        let hostingView = NSHostingView(rootView: view)

        return hostingView.fittingSize.width
    }
}
