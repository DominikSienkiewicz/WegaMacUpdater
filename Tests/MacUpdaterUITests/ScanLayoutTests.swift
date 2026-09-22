import SwiftUI
import XCTest
@testable import WegaMacUpdater

/// A scan changes several pieces of window chrome at once. The sidebar must keep the same
/// geometry throughout that transition; changing its safe-area padding makes NSSplitView
/// repeatedly solve constraints until AppKit aborts the process.
final class ScanLayoutTests: XCTestCase {
    @MainActor
    func testSidebarKeepsItsWidthWhenScanActivityChanges() {
        let idleWidth = fittingWidth(for: .idle)
        let scanningWidth = fittingWidth(for: .scanning)

        XCTAssertEqual(scanningWidth, idleWidth, accuracy: 0.5)
    }

    @MainActor
    func testToolbarControlKeepsItsWidthWhenScanStatusChanges() {
        let readyWidth = toolbarFittingWidth(for: .ready)
        let checkingWidth = toolbarFittingWidth(for: .checking)

        XCTAssertEqual(checkingWidth, readyWidth, accuracy: 0.5)
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
            updateActivity: activity
        )
        let hostingView = NSHostingView(rootView: view)

        return hostingView.fittingSize.width
    }

    /// The quiet launch refresh is a third way the toolbar shows **Cancel** — with `status`
    /// left on `.results`, where the two assertions above never look. A control that changes
    /// width there invalidates the window safe area exactly as one that changes width on
    /// `.checking` does.
    @MainActor
    func testToolbarControlKeepsItsWidthWhenAQuietRefreshStartsAndStops() {
        let idleWidth = toolbarFittingWidth(for: .results)
        let refreshingWidth = toolbarFittingWidth(for: .results, refreshing: true)

        XCTAssertEqual(refreshingWidth, idleWidth, accuracy: 0.5)
    }

    @MainActor
    private func toolbarFittingWidth(for status: UpdateStatus, refreshing: Bool = false) -> CGFloat {
        let scan = ScanStore()
        scan.status = status
        scan.setRefreshing(refreshing)
        let hostingView = NSHostingView(
            rootView: ScanControlHarness().environmentObject(scan)
        )

        return hostingView.fittingSize.width
    }
}

private struct ScanControlHarness: View {
    @Namespace private var namespace

    var body: some View {
        ScanControl(namespace: namespace)
    }
}
