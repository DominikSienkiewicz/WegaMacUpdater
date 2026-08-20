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

    /// The inspector used to close itself on every language switch: `showInspector` was `@State`
    /// on `ContentView`, and `.id(localization.language)` hands that view a fresh identity, which
    /// discards its state. The flag belongs above the re-key, in `WegaMacUpdaterApp` — where
    /// `ScanStore`, `MigrationStore` and `WegaCommandCenter` already sit for exactly this reason.
    ///
    /// Deliberately NOT `@AppStorage`: a persisted `true` would present the inspector during the
    /// window's first layout pass, which is the crash the test above exists to prevent. Held as
    /// `@State` on the `App`, it survives a language switch and still starts closed every launch.
    ///
    /// Source inspection, like its neighbours in this target: a package test cannot drive
    /// `XCUIApplication`, so the SwiftUI ownership is pinned here instead.
    func testInspectorVisibilityOutlivesTheLanguageReKey() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")
        XCTAssertFalse(
            content.contains("@State private var showInspector"),
            "showInspector must not be @State on ContentView — .id(localization.language) discards it."
        )
        XCTAssertTrue(
            content.contains("@Binding private var showInspector"),
            "ContentView must receive the inspector flag as a binding from the scene root."
        )

        let app = try source("Sources/MacUpdater/MacUpdaterApp.swift")
        XCTAssertTrue(
            app.contains("@State private var showInspector"),
            "The scene root must own the inspector flag, above .id(localization.language)."
        )
        XCTAssertTrue(
            app.contains("ContentView.showsInspectorAtLaunch"),
            "The scene root must seed the flag from showsInspectorAtLaunch, keeping launch closed."
        )
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
