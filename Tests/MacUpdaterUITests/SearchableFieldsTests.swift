import XCTest

@testable import WegaMacUpdater

/// UX-11c — the app's search inputs use SwiftUI's native `.searchable`, not hand-built
/// `TextField`s. A package test target cannot drive `XCUIApplication`, so — like the other
/// UI-wiring tests here — this pins the contract by inspecting the view sources: every view
/// that offers a search field adopts `.searchable(text:)` and keeps no manual "Szukaj…"
/// `TextField` fallback.
final class SearchableFieldsTests: XCTestCase {
    private let searchViews = [
        "Sources/MacUpdater/InventoryView.swift",
        "Sources/MacUpdater/LogsView.swift",
        "Sources/MacUpdater/UninstallView.swift",
        "Sources/MacUpdater/UpdatesSearch.swift",
    ]

    func testSearchViewsAdoptSearchableModifier() throws {
        for path in searchViews {
            let contents = try source(path)
            XCTAssertTrue(
                contents.contains(".searchable(text: $search"),
                "\(path) must drive its search through `.searchable(text:)`"
            )
        }
    }

    func testSearchViewsKeepNoHandBuiltSearchField() throws {
        for path in searchViews {
            let contents = try source(path)
            XCTAssertFalse(
                contents.contains("TextField(tr(\"Szukaj"),
                "\(path) must not keep a manual search `TextField`"
            )
        }
    }

    /// UX-10's ⌘F focuses the inventory search; with `.searchable` that runs through
    /// `.searchFocused`, so the command must keep a documented way in.
    func testInventorySearchStaysReachableByCommandF() throws {
        let inventory = try source("Sources/MacUpdater/InventoryView.swift")
        XCTAssertTrue(
            inventory.contains(".searchFocused($searchFocused)"),
            "the inventory `.searchable` field must bind `.searchFocused` so ⌘F can focus it"
        )
    }

    /// Cleanup's report is long; its search narrows it, and ⌘F reaches the field.
    func testCleanupSearchIsReachableByCommandF() throws {
        let cleanup = try source("Sources/MacUpdater/CleanupView.swift")
        XCTAssertTrue(cleanup.contains(".searchable(text: $search"))
        XCTAssertTrue(cleanup.contains(".searchFocused($searchFocused)"))
        XCTAssertTrue(cleanup.contains(".receivesSearchFocusRequests(on: .cleanup)"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
