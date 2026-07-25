import AppKit
import MacUpdaterCore
import SwiftUI
import XCTest

@testable import WegaMacUpdater

/// QA-02 — the interaction contract around the three accessibility fixes linked from the
/// backlog. These tests intentionally inspect both rendered sizing and SwiftUI wiring: a
/// package test target cannot drive `XCUIApplication`, but it can still pin the native
/// controls, keyboard actions and environment values that make those behaviours possible.
final class AccessibilityInteractionTests: XCTestCase {
    func testSelectionControlsExposeButtonRoleLabelAndValue() throws {
        let sharedViews = try source("Sources/MacUpdater/SharedViews.swift")
        let packageRow = try section(
            in: sharedViews,
            startingAt: "struct PackageRow: View",
            endingAt: "// MARK: - Rollback badge"
        )

        XCTAssertTrue(packageRow.contains("Button(action: onToggle)"))
        XCTAssertTrue(packageRow.contains(".accessibilityLabel(name)"))
        XCTAssertTrue(
            packageRow.contains(".accessibilityValue(selectionAccessibilityValue(isSelected))"))
        XCTAssertFalse(packageRow.contains(".onTapGesture { onToggle?() }"))

        let uninstall = try source("Sources/MacUpdater/UninstallView.swift")
        XCTAssertTrue(
            uninstall.contains(".accessibilityLabel(selectionAccessibilityLabel(for: app"))
        XCTAssertTrue(
            uninstall.contains(".accessibilityValue(selectionAccessibilityValue(isSelected))"))
        XCTAssertFalse(uninstall.contains(".onTapGesture { toggle(app.id) }"))
    }

    func testSelectionAccessibilityValuesDistinguishBothStates() {
        XCTAssertEqual(selectionAccessibilityValue(false), tr("Niezaznaczone"))
        XCTAssertEqual(selectionAccessibilityValue(true), tr("Zaznaczone"))
        XCTAssertNotEqual(selectionAccessibilityValue(false), selectionAccessibilityValue(true))
    }

    func testSidebarAndUpdateRowsHaveDeterministicKeyboardFocusOrder() throws {
        let sidebar = try source("Sources/MacUpdater/SidebarList.swift")
        let orderedRows = [
            "row(.updates(.all)",
            "row(.updates(.apps)",
            "row(.updates(.cli)",
            "row(.updates(.security)",
            "row(.migration)",
            "row(.inventory)",
            "row(.uninstall)",
            "row(.logs",
        ]
        let positions = try orderedRows.map { marker in
            try XCTUnwrap(
                sidebar.range(of: marker)?.lowerBound, "Missing focusable sidebar row: \(marker)")
        }
        for (earlier, later) in zip(positions, positions.dropFirst()) {
            XCTAssertLessThan(
                earlier, later, "Sidebar source order defines native keyboard focus order")
        }

        let sharedViews = try source("Sources/MacUpdater/SharedViews.swift")
        let packageRow = try section(
            in: sharedViews,
            startingAt: "struct PackageRow: View",
            endingAt: "// MARK: - Rollback badge"
        )
        XCTAssertTrue(packageRow.contains(".focusable(onSelect != nil)"))
        XCTAssertTrue(packageRow.contains(".onKeyPress(.return)"))
        XCTAssertTrue(packageRow.contains(".onKeyPress(.space)"))
    }

    func testSelectionAndMigrationActionsUseKeyboardControlsInsteadOfGestures() throws {
        let update = try source("Sources/MacUpdater/UpdateView.swift")
        let selectAllRow = try section(
            in: update,
            startingAt: "// Select-all row",
            endingAt: "ScrollView {"
        )
        XCTAssertTrue(selectAllRow.contains("Button"))
        XCTAssertTrue(selectAllRow.contains("scan.toggleAll(filter: updateFilter)"))
        XCTAssertFalse(selectAllRow.contains("onTapGesture"))

        let migration = try source("Sources/MacUpdater/MigrationView.swift")
        let migrationRow = try section(
            in: migration,
            startingAt: "private struct MigrationRow: View",
            endingAt: "private struct AppStoreMigrationRow: View"
        )
        XCTAssertTrue(migrationRow.contains("Button"))
        XCTAssertFalse(migrationRow.contains("onTapGesture"))
    }

    func testReduceMotionStopsContinuousAnimations() throws {
        let sniffingScene = try source("Sources/MacUpdater/SniffingScene.swift")
        XCTAssertTrue(sniffingScene.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(sniffingScene.contains("guard !reduceMotion else"))

        let sidebar = try source("Sources/MacUpdater/SidebarList.swift")
        XCTAssertTrue(sidebar.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(sidebar.contains("activity == .scanning && !reduceMotion"))
    }

    @MainActor
    func testPackageRowReflowsWithLargeEnvironmentText() {
        let regularHeight = packageRowHeight(font: .body)
        let accessibilityHeight = packageRowHeight(font: .system(size: 32))

        XCTAssertGreaterThan(
            accessibilityHeight,
            regularHeight + 4,
            "Semantic fonts must reflow rather than remain fixed at accessibility text sizes"
        )
    }

    func testUninstallConfirmationIsNativeDestructiveAndKeyboardOperable() throws {
        let uninstall = try source("Sources/MacUpdater/UninstallView.swift")

        XCTAssertTrue(uninstall.contains(".sheet(isPresented: $showDialog)"))
        XCTAssertTrue(uninstall.contains("Button(tr(\"Anuluj\"), role: .cancel"))
        XCTAssertTrue(uninstall.contains("Button(confirmLabel, role: .destructive)"))
        XCTAssertTrue(uninstall.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(uninstall.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertFalse(uninstall.contains("// MARK: - Custom uninstall dialog (ZStack overlay)"))
    }

    @MainActor
    func testChangingUpdateFilterDropsSelectionsThatBecomeHidden() {
        let formulaName = "qa02-formula-\(UUID().uuidString)"
        let caskName = "qa02-cask-\(UUID().uuidString)"
        let scan = ScanStore()
        scan.brewOutdated = BrewOutdated(
            formulae: [
                BrewOutdatedItem(
                    name: formulaName,
                    installedVersions: ["1"],
                    currentVersion: "2"
                )
            ],
            casks: [
                BrewOutdatedItem(
                    name: caskName,
                    installedVersions: ["1"],
                    currentVersion: "2"
                )
            ]
        )
        scan.selected = ["f:\(formulaName)", "c:\(caskName)"]

        scan.restrictSelection(to: .apps)

        XCTAssertEqual(scan.selected, ["c:\(caskName)"])
        XCTAssertEqual(scan.updateTargets(for: .apps).map(\.key), ["c:\(caskName)"])
    }

    func testUninstallSelectionCannotRetainAnItemHiddenBySearch() {
        let visible = application("/Applications/Visible.app", name: "Visible")
        let hidden = application("/Applications/Hidden.app", name: "Hidden")

        let targets = InstallationInventory.selected(
            [visible],
            identities: [visible.id, hidden.id]
        )

        XCTAssertEqual(targets.map(\.id), [visible.id])
    }

    @MainActor
    private func packageRowHeight(font: Font) -> CGFloat {
        let row = PackageRow(
            name: "Accessibility Regression Package",
            token: "accessibility-regression-package",
            currentVersion: "1.0.0",
            latestVersion: "2.0.0",
            isSelected: true,
            onToggle: {}
        )
        .environment(\.font, font)
        .frame(width: 420)
        let hostingView = NSHostingView(rootView: row)

        return hostingView.fittingSize.height
    }

    private func application(_ path: String, name: String) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path),
            name: name,
            bundleIdentifier: "qa02.\(name)",
            version: "1",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func section(
        in source: String,
        startingAt start: String,
        endingAt end: String
    ) throws -> Substring {
        let lowerBound = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let upperBound = try XCTUnwrap(
            source.range(of: end, range: lowerBound..<source.endIndex)?.lowerBound
        )
        return source[lowerBound..<upperBound]
    }
}
