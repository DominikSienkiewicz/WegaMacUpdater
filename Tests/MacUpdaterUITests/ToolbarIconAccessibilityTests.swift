import XCTest

@testable import WegaMacUpdater

/// UX-11e — the detail column's toolbar carries two icon-only controls: the `gearshape`
/// `SettingsLink` and the `sidebar.trailing` inspector toggle. Both spoke only through `.help()`,
/// which AppKit surfaces as a hover tooltip but never as a VoiceOver name, so the buttons read as
/// bare SF Symbol glyphs. Each icon must now carry an `.accessibilityLabel` alongside its `.help()`.
///
/// A package test target cannot drive `XCUIApplication`, so this pins the SwiftUI wiring in source.
final class ToolbarIconAccessibilityTests: XCTestCase {
    func testSettingsIconExposesAnAccessibilityLabel() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")
        XCTAssertTrue(
            content.contains(#".accessibilityLabel(tr("Ustawienia"))"#),
            "The gearshape SettingsLink must spell its name for VoiceOver, not only .help()."
        )
    }

    func testInspectorToggleIconExposesAnAccessibilityLabel() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")
        XCTAssertTrue(
            content.contains(#".accessibilityLabel(tr("Panel szczegółów"))"#),
            "The sidebar.trailing inspector toggle must spell its name for VoiceOver, not only .help()."
        )
    }

    /// Every icon-only toolbar button pairs `.help(...)` with a matching `.accessibilityLabel(...)`.
    func testEveryHelpOnlyToolbarIconAlsoCarriesAnAccessibilityLabel() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")
        let helpCount = content.components(separatedBy: ".help(tr(").count - 1
        let labelCount = content.components(separatedBy: ".accessibilityLabel(tr(").count - 1
        XCTAssertGreaterThanOrEqual(
            labelCount, helpCount,
            "Each toolbar icon guarded by .help() must also carry an .accessibilityLabel()."
        )
    }

    /// The language switcher used to live only in the Settings window, three cards down behind
    /// the gear icon. A user who cannot read the interface cannot read their way to it either —
    /// so the main window's toolbar carries a `globe` menu, an icon that needs no translation.
    ///
    /// Source inspection, like its neighbours: a package test target cannot drive
    /// `XCUIApplication`, so the SwiftUI wiring is pinned here instead.
    func testToolbarCarriesAGlobeLanguageMenu() throws {
        let content = try source("Sources/MacUpdater/ContentView.swift")
        XCTAssertTrue(
            content.contains(#"Image(systemName: "globe")"#),
            "The main window's toolbar must offer a globe control for switching language."
        )
        XCTAssertTrue(
            content.contains("selection: $localization.language"),
            "The globe menu must drive LocalizationManager.language, not a local copy of it."
        )
        XCTAssertTrue(
            content.contains(#".accessibilityLabel(tr("Język interfejsu"))"#),
            "The globe icon must spell its name for VoiceOver, not only .help()."
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
