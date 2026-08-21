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
    /// UX-02 narrowed the contract this test pins: a selection control is no longer a
    /// `Button` that carries a value, it is a `Toggle` — so VoiceOver announces a checkbox
    /// with a state instead of a button with a value, and the space bar activates it as a
    /// system control rather than through a hand-rolled key handler. The label still has to
    /// come from the call site (the row's own name), and the gesture still has to be gone.
    func testSelectionControlsExposeCheckboxRoleLabelAndValue() throws {
        let sharedViews = try source("Sources/MacUpdater/SharedViews.swift")
        let packageRow = try section(
            in: sharedViews,
            startingAt: "struct PackageRow: View",
            endingAt: "// MARK: - Rollback badge"
        )

        XCTAssertTrue(packageRow.contains("Toggle(isOn: selectionToggleBinding(isOn: isSelected, toggle: onToggle))"))
        XCTAssertTrue(packageRow.contains(".toggleStyle(WegaCheckboxToggleStyle())"))
        XCTAssertTrue(packageRow.contains(".accessibilityLabel(name)"))
        XCTAssertFalse(packageRow.contains(".onTapGesture { onToggle?() }"))

        let uninstall = try source("Sources/MacUpdater/UninstallView.swift")
        XCTAssertTrue(uninstall.contains("Toggle(isOn: selectionToggleBinding(isOn: isSelected)"))
        XCTAssertTrue(
            uninstall.contains(".accessibilityLabel(selectionAccessibilityLabel(for: app"))
        XCTAssertFalse(uninstall.contains(".onTapGesture { toggle(app.id) }"))
    }

    /// The role and the state live in the style, once, instead of at every call site — which
    /// is the point of moving to `Toggle` at all. A custom `ToggleStyle` takes over the whole
    /// rendering, so it has to restate the semantics SwiftUI would otherwise supply.
    func testCheckboxStyleCarriesRoleAndStateForEveryCallSite() throws {
        let sharedViews = try source("Sources/MacUpdater/SharedViews.swift")
        let style = try section(
            in: sharedViews,
            startingAt: "struct WegaCheckboxToggleStyle: ToggleStyle",
            endingAt: "func selectionToggleBinding"
        )

        XCTAssertTrue(style.contains(".accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : .isToggle)"),
                      "a custom style that drops the toggle trait announces itself as a plain button")
        XCTAssertTrue(style.contains(".accessibilityValue(selectionAccessibilityValue(configuration.isOn))"))
        XCTAssertTrue(style.contains("configuration.isOn.toggle()"),
                      "activation must flow through the binding, not a side-channel callback")
    }

    /// Every migration row carries an identically-labelled action button, so the label alone
    /// tells a VoiceOver user nothing about which app they are about to act on.
    func testMigrationActionsNameTheAppTheyActOn() throws {
        let migration = try source("Sources/MacUpdater/MigrationView.swift")

        XCTAssertTrue(migration.contains(".accessibilityLabel(trf(\"Przepnij %@ do Homebrew\", app.name))"))
        XCTAssertTrue(migration.contains(".accessibilityLabel(trf(\"Otwórz %@ w App Store\", app.name))"))
        XCTAssertTrue(migration.contains(".accessibilityLabel(trf(\"Usuń %@ z npm\", dup.npmPackage))"))
        XCTAssertTrue(migration.contains(".accessibilityLabel(trf(\"Usuń %@ z brew\", dup.brewToken))"))
    }

    /// The select-all control stays a `Button` on purpose: it has three states (none, some,
    /// all) and `Toggle` has two. A checkbox that cannot say "some" would misreport a partial
    /// selection as one of the other two — so it keeps the spoken count instead.
    func testSelectAllStaysAnActionThatReportsItsPartialState() throws {
        let update = try source("Sources/MacUpdater/UpdateView.swift")
        let selectAllRow = try section(
            in: update,
            startingAt: "// Select-all row",
            endingAt: "ScrollView {"
        )

        // The three-state control itself moved into the shared `SelectionCheckbox` when
        // every checkbox became one column: the row still supplies the state and the spoken
        // count, the shared view supplies the role and the glyph.
        XCTAssertTrue(selectAllRow.contains("SelectionCheckbox("))
        XCTAssertTrue(selectAllRow.contains("state: selectAllState"))
        XCTAssertFalse(selectAllRow.contains("Toggle("),
                       "a two-state Toggle cannot represent a partial selection")
        XCTAssertTrue(selectAllRow.contains("accessibilityValue: selectionSummary"))
        XCTAssertTrue(update.contains("%@ z %@ zaznaczonych"),
                      "the spoken value must carry the count a mixed checkbox could not")

        let sharedViews = try source("Sources/MacUpdater/SharedViews.swift")
        XCTAssertTrue(sharedViews.contains("Button(action: toggle)"),
                      "the select-all control stays an action, not a two-state checkbox")
        XCTAssertTrue(sharedViews.contains("case .partial: return \"minus.square.fill\""),
                      "the partial state must remain visually distinct too")
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
        XCTAssertTrue(selectAllRow.contains("SelectionCheckbox("))
        XCTAssertTrue(selectAllRow.contains("scan.toggleAll(filter: updateFilter)"))
        XCTAssertFalse(selectAllRow.contains("onTapGesture"))

        // `SelectionCheckbox` is a `Button`, so the space bar activates it as a system
        // control — which is what replaced the tap gesture this test forbids.
        let sharedSelection = try source("Sources/MacUpdater/SharedViews.swift")
        XCTAssertTrue(sharedSelection.contains("Button(action: toggle)"))

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
