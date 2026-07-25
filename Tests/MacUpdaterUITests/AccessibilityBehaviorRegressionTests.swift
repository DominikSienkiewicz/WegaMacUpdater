import AppKit
import MacUpdaterCore
import SwiftUI
import XCTest

@testable import WegaMacUpdater

final class AccessibilityBehaviorRegressionTests: XCTestCase {
  func testReduceMotionSelectsAStaticFrameInsteadOfAnAnimationSchedule() {
    let staticMode = BinaryStreamMotionMode(reduceMotion: true)
    let animatedMode = BinaryStreamMotionMode(reduceMotion: false)

    XCTAssertEqual(staticMode, .staticFrame(BinaryStreamMotionMode.referenceDate))
    XCTAssertEqual(animatedMode, .animated(minimumInterval: 1.0 / 30.0))
    XCTAssertEqual(
      staticMode.renderDate(at: Date(timeIntervalSinceReferenceDate: 100)),
      staticMode.renderDate(at: Date(timeIntervalSinceReferenceDate: 200))
    )
    XCTAssertNotEqual(
      animatedMode.renderDate(at: Date(timeIntervalSinceReferenceDate: 100)),
      animatedMode.renderDate(at: Date(timeIntervalSinceReferenceDate: 200))
    )
  }

  @MainActor
  func testPackageRowKeyboardHandlerInvokesOnlyTheMappedAction() {
    var inspections = 0
    var toggles = 0
    let inspect = { inspections += 1 }
    let toggle = { toggles += 1 }

    _ = PackageRowKeyboardBehavior.handle(
      .inspect,
      onSelect: inspect,
      onToggle: toggle
    )
    XCTAssertEqual(inspections, 1)
    XCTAssertEqual(toggles, 0)

    _ = PackageRowKeyboardBehavior.handle(
      .toggleSelection,
      onSelect: inspect,
      onToggle: toggle
    )
    XCTAssertEqual(inspections, 1)
    XCTAssertEqual(toggles, 1)
  }

  func testSidebarFocusPolicyIsCompleteAndDeterministic() {
    XCTAssertEqual(
      SidebarFocusPolicy.orderedSelections,
      [
        .updates(.all),
        .updates(.apps),
        .updates(.cli),
        .updates(.security),
        .migration,
        .inventory,
        .uninstall,
        .logs,
      ]
    )
    XCTAssertEqual(Set(SidebarFocusPolicy.orderedSelections).count, 8)
    for (earlier, later) in zip(
      SidebarFocusPolicy.orderedSelections,
      SidebarFocusPolicy.orderedSelections.dropFirst()
    ) {
      XCTAssertGreaterThan(
        SidebarFocusPolicy.accessibilityPriority(for: earlier),
        SidebarFocusPolicy.accessibilityPriority(for: later)
      )
    }
  }

  @MainActor
  func testFilterTransitionClearsInspectionAndDropsHiddenSelection() {
    let formulaName = "qa-bg-formula-\(UUID().uuidString)"
    let caskName = "qa-bg-cask-\(UUID().uuidString)"
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
    scan.inspectedKey = "f:\(formulaName)"

    UpdateFilterInteraction.apply(.apps, to: scan)

    XCTAssertNil(scan.inspectedKey)
    XCTAssertEqual(scan.selected, ["c:\(caskName)"])
    XCTAssertEqual(scan.updateTargets(for: .apps).map(\.key), ["c:\(caskName)"])
  }

  @MainActor
  func testUninstallSheetHasUsableIntrinsicSize() {
    let target = application(
      "/Applications/QA BG Review.app",
      name: "QA BG Review",
      managedByBrew: true
    )
    let hostingView = NSHostingView(
      rootView: UninstallDialog(
        targets: [target],
        ambiguities: [],
        onCancel: {},
        onConfirm: { _ in }
      )
    )

    XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 480)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 300)
  }

  func testUninstallOptionSemanticsExposeBothSelectionStates() {
    let selected = UninstallOptionAccessibilitySemantics(
      title: "App + leftovers",
      isSelected: true
    )
    let unselected = UninstallOptionAccessibilitySemantics(
      title: "App only",
      isSelected: false
    )

    XCTAssertEqual(selected.label, "App + leftovers")
    XCTAssertEqual(selected.value, selectionAccessibilityValue(true))
    XCTAssertTrue(selected.isSelected)
    XCTAssertEqual(unselected.value, selectionAccessibilityValue(false))
    XCTAssertFalse(unselected.isSelected)
  }

  func testDestructiveDialogKeyboardBehaviorKeepsCancelAndConfirmSeparate() {
    var cancellations = 0
    var confirmations: [Bool] = []

    UninstallDialogKeyboardBehavior.perform(
      .cancel,
      zapMode: true,
      onCancel: { cancellations += 1 },
      onConfirm: { confirmations.append($0) }
    )
    XCTAssertEqual(cancellations, 1)
    XCTAssertTrue(confirmations.isEmpty)

    UninstallDialogKeyboardBehavior.perform(
      .confirm,
      zapMode: true,
      onCancel: { cancellations += 1 },
      onConfirm: { confirmations.append($0) }
    )
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(confirmations, [true])
  }

  private func application(
    _ path: String,
    name: String,
    managedByBrew: Bool = false
  ) -> ApplicationInfo {
    ApplicationInfo(
      path: URL(fileURLWithPath: path),
      name: name,
      bundleIdentifier: "qa-bg.\(name)",
      version: "1",
      installDate: nil,
      updateDate: nil,
      isManagedByBrew: managedByBrew,
      caskToken: managedByBrew ? "qa-bg-review" : nil
    )
  }
}
