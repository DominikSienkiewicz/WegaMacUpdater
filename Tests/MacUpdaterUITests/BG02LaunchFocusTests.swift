import Foundation
import Testing

/// BG-02 — a window appearing must not take the keyboard away from whatever the user is doing.
///
/// The card gave Wega a "Launch at login" switch so the background mode survives a reboot. It
/// did not ask what happens *at* that login, and the answer was: the `WindowGroup` body called
/// `NSApplication.shared.activate(ignoringOtherApps: true)` from `.onAppear`, unconditionally.
/// So every login brought Wega's main window up over whatever the user had opened and took the
/// focus with it. A user meeting that once turns the switch back off, which makes the whole
/// card deliver something nobody keeps enabled.
///
/// Activation belongs to paths the user actually initiated — the menu bar's "Otwórz Wega", and
/// the modal alert that has to be seen before the app quits mid-mutation. A window simply
/// appearing is not one of them: on an ordinary Finder or Dock launch macOS already fronts the
/// app, so the call added nothing there and only ever cost something everywhere else.
///
/// Asserted at source level: `@main` scene composition has no seam a unit test can drive, and
/// `NSApp` does not exist in a test process at all.
@Suite("BG-02 — an appearing window does not steal focus")
struct BG02LaunchFocusTests {

    /// Red before the fix: `MacUpdaterApp.swift` contained
    /// `.onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }` inside the
    /// `WindowGroup`, so the focus grab fired on every launch — including the one nobody asked
    /// for, at login.
    @Test func theWindowGroupDoesNotActivateTheAppWhenItsWindowAppears() throws {
        let scene = try slice(appSource(), from: "WindowGroup(id: \"main\") {", to: "Settings {")

        #expect(!scene.contains("activate("),
                """
                BG-02: the WindowGroup must not activate the app. A window appearing is not a \
                user gesture, and at login it is the app interrupting someone mid-task.
                """)
    }

    /// The other half of the same rule: activation is still allowed, and still happens, where
    /// the user asked for it. This is what stops the fix above from being read as "remove every
    /// activate call" by whoever touches this next.
    @Test func activationSurvivesOnTheUserInitiatedPaths() throws {
        let menuBar = try read("Sources/MacUpdater/MenuBarScene.swift")
        let openCommand = try slice(menuBar, from: "Button(tr(\"Otwórz Wega\"))", to: "Divider()")

        #expect(openCommand.contains("activate("),
                "BG-02: choosing \"Otwórz Wega\" is a gesture — that window is meant to come forward")

        let quitAlert = try slice(appSource(), from: "alert.addButton(withTitle: tr(\"Anuluj\"))", to: "alert.runModal()")
        #expect(quitAlert.contains("activate("),
                "REL-06: the quit-during-mutation alert must be seen, so it is allowed to front the app")
    }

    // MARK: Helpers

    private func read(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func appSource() throws -> String {
        try read("Sources/MacUpdater/MacUpdaterApp.swift")
    }

    private func slice(_ text: String, from: String, to: String) throws -> String {
        let start = try #require(text.range(of: from))
        let region = text[start.lowerBound...]
        let end = try #require(region.range(of: to))
        return String(region[..<end.lowerBound])
    }
}
