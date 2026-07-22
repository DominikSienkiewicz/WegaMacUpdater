import XCTest
@testable import WegaMacUpdater

/// macOS can recursively invalidate `NavigationSplitView` constraints when a native inspector
/// is already presented during the window's first layout pass. Keep it closed until the user
/// explicitly asks for it from the toolbar.
final class StartupLayoutTests: XCTestCase {
    @MainActor
    func testInspectorIsClosedDuringInitialWindowLayout() {
        XCTAssertFalse(ContentView.showsInspectorAtLaunch)
    }
}
