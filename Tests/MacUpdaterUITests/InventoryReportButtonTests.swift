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

    func testReportButtonInvokesCatalogIssueBuilderAndOpensPrefilledIssue() throws {
        let inventory = try source("Sources/MacUpdater/InventoryView.swift")
        XCTAssertTrue(inventory.contains("private struct ReportAppButton: View"))
        XCTAssertTrue(inventory.contains("Button(action: report)"))
        XCTAssertTrue(inventory.contains("CatalogReporting.issueBuilder(for: app)"))
        XCTAssertTrue(inventory.contains("newIssueEndpoint: AppEndpoints.shared.projectNewIssueURL"))
        XCTAssertTrue(inventory.contains("NSWorkspace.shared.open(url)"))
        XCTAssertTrue(inventory.contains(".accessibilityLabel(tr(\"Zgłoś aplikację\"))"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
