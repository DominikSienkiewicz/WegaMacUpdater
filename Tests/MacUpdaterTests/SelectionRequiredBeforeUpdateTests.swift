import Foundation
import Testing
@testable import MacUpdaterCore

/// The batch-update button used to mean "everything" when the user had ticked nothing: the
/// widest action in the app was the one reached by doing nothing at all. Selection is now a
/// precondition, and these checks pin the three places that could quietly restore the old
/// meaning — the planner, the target resolver, and the button's own wiring.
@Suite("Selection required before update")
struct SelectionRequiredBeforeUpdateTests {
    private let updates = [
        OutdatedItem(key: "f:wget", name: "wget", from: "1", to: "2", kind: .formula),
        OutdatedItem(key: "c:firefox", name: "Firefox", from: "1", to: "2", kind: .cask),
        OutdatedItem(key: "c:slack", name: "Slack", from: "1", to: "2", kind: .cask),
        OutdatedItem(key: "a:1", name: "Xcode", from: "1", to: "2", kind: .appStore),
    ]

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func nothingSelectedMeansNothingToUpdate() {
        #expect(UpdatePlanner.targets(from: updates, selectedKeys: [], filter: .all).isEmpty)
    }

    @Test func onlyTickedRowsBecomeTargets() {
        let targets = UpdatePlanner.targets(from: updates, selectedKeys: ["c:slack"], filter: .all)

        #expect(targets.map(\.key) == ["c:slack"])
    }

    /// The disabled state and the button's count must be read from the same value, or the
    /// button can offer "Update selected (0)" as a live control.
    @Test func theButtonIsDisabledByTheSameEmptinessItCounts() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")

        #expect(view.contains(".disabled(scan.updating || updateTargets.isEmpty)"),
                "an empty selection must disable the batch-update button")
        #expect(!view.contains("Zaktualizuj wszystkie"),
                "no label may promise an upgrade the user did not select")
    }

    /// A dead control with no stated reason is its own defect: the screen has to say what is
    /// missing before the user goes looking for a broken button.
    @Test func theDisabledButtonSaysWhatIsMissing() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")

        #expect(view.contains("Zaznacz, co mam zaktualizować"),
                "the empty-selection state must carry a visible hint, not just a dimmed button")
    }

    /// Groups are selectable as a unit, and each group speaks only for its own rows.
    @Test func aGroupCheckboxSelectsAndClearsExactlyItsOwnRows() {
        let casks = ["c:firefox", "c:slack"]

        let ticked = UpdatePlanner.toggledGroup(selected: ["f:wget"], groupKeys: casks)
        #expect(ticked == ["f:wget", "c:firefox", "c:slack"])
        #expect(UpdatePlanner.groupSelectionState(selected: ticked, groupKeys: casks) == .all)

        let cleared = UpdatePlanner.toggledGroup(selected: ticked, groupKeys: casks)
        #expect(cleared == ["f:wget"], "clearing a group must not touch another group's rows")
        #expect(UpdatePlanner.groupSelectionState(selected: cleared, groupKeys: casks) == .none)
    }

    /// Every checkbox on the Updates screen shares one column. The card-internal ones get
    /// there through the card's padding; the list-wide one has to add the gutter itself.
    @Test func everySelectionControlSitsInOneColumn() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")

        #expect(view.contains(".padding(.leading, WegaLayout.selectionColumnInset)"),
                "the list-wide select-all control must reproduce the card inset, not float free")
        #expect(!view.contains(".padding(.horizontal, 20)"),
                "a hand-picked inset puts the select-all checkbox in a column of its own")
        #expect(support.contains("selection: SelectionCheckbox("),
                "each update section must offer a checkbox for the whole group")
    }
}
