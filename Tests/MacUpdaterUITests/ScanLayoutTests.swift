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
            selection: .constant(.default),
            appsBadge: 0,
            cliBadge: 0,
            securityBadge: 0,
            logsErrorBadge: 0,
            updateActivity: activity
        )
        let hostingView = NSHostingView(rootView: view)

        return hostingView.fittingSize.width
    }

    @MainActor
    private func toolbarFittingWidth(for status: UpdateStatus) -> CGFloat {
        let scan = ScanStore()
        scan.status = status
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
