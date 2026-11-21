import MacUpdaterCore
import SwiftUI
import XCTest

@testable import WegaMacUpdater

/// UX-14 — pins the Inventory "report this app" affordance. A package test target cannot drive
/// `XCUIApplication`, so this asserts the SwiftUI wiring in source: the button is rendered only for
/// an app with no known update source, and its action runs the prefilled-issue flow end to end
/// (`CatalogIssueBuilder` → the `projectNewIssue` endpoint → `NSWorkspace.open`).
final class InventoryReportButtonTests: XCTestCase {
    func testReportButtonIsGatedOnAppsWithoutAKnownSource() throws {
        let inventory = try source("Sources/MacUpdater/InventoryView.swift")
        XCTAssertTrue(
            inventory.contains("if !CatalogReporting.hasKnownUpdateSource(app, catalog: .shared)"),
            "the report button must render only for apps Wega cannot already update"
        )
        XCTAssertTrue(inventory.contains("ReportAppButton(app: app)"))
    }

    /// The button lives in its own file since ⌘F's no-source answer reuses it as a link; the icon
    /// form Inventory draws and the report flow are unchanged.
    func testReportButtonInvokesCatalogIssueBuilderAndOpensPrefilledIssue() throws {
        let button = try source("Sources/MacUpdater/ReportAppButton.swift")
        XCTAssertTrue(button.contains("struct ReportAppButton: View"))
        XCTAssertTrue(button.contains("Button(action: report)"))
        XCTAssertTrue(button.contains("Image(systemName: \"plus.bubble\")"))
        XCTAssertTrue(button.contains(".help(tr(\"Zgłoś tę aplikację do katalogu\"))"))
        XCTAssertTrue(button.contains("Button(tr(\"Zgłoś aplikację ›\"), action: report)"))
        XCTAssertTrue(button.contains("CatalogReporting.issueBuilder(for: app)"))
        XCTAssertTrue(button.contains("newIssueEndpoint: AppEndpoints.shared.projectNewIssueURL"))
        XCTAssertTrue(button.contains("NSWorkspace.shared.open(url)"))
        XCTAssertEqual(button.components(separatedBy: ".accessibilityLabel(tr(\"Zgłoś aplikację\"))").count - 1, 2,
                       "both forms carry the same VoiceOver label")
        let inventory = try source("Sources/MacUpdater/InventoryView.swift")
        XCTAssertFalse(inventory.contains("struct ReportAppButton"), "one definition, in its own file")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
