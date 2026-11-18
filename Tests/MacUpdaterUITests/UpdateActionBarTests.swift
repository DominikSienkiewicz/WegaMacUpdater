import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UX-14 — the Updates screen spread one flow over three places: a select-all row above the
/// list, the update button in the results header and the plan in a disclosure between them.
/// One bar under the list now carries the selection, the rollback coverage, the plan and the
/// update itself.
@Suite("Update action bar")
@MainActor
struct UpdateActionBarTests {
    @Test func anEmptySelectionAsksForOne() {
        let summary = UpdateActionBarSummary(selectedCount: 0, visibleCount: 3, targets: [], protection: [:])

        #expect(summary.selectionText == tr("Zaznacz, co mam zaktualizować"))
        #expect(summary.protectionText == nil, "nothing ticked means nothing to cover")
    }

    @Test func theSelectionIsCountedAgainstTheVisibleRows() {
        let summary = UpdateActionBarSummary(selectedCount: 2, visibleCount: 5, targets: [], protection: [:])

        #expect(summary.selectionText == trf("%@ z %@ zaznaczonych", "2", "5"))
    }

    /// The bar may only promise the rollback net for what the net really covers: ticked casks
    /// whose verdict is `.protected`. A formula never qualifies, whatever a stray map entry says.
    @Test func onlyProtectedCaskTargetsCountAsCoveredByRollback() {
        let targets = [
            OutdatedItem(key: "c:firefox", name: "firefox", from: "1", to: "2", kind: .cask),
            OutdatedItem(key: "c:raycast", name: "raycast", from: "1", to: "2", kind: .cask),
            OutdatedItem(key: "f:wget", name: "wget", from: "1", to: "2", kind: .formula),
        ]
        let protection: [String: RollbackProtection.Verdict] = [
            "firefox": .protected,
            "raycast": .unprotected(.noAppBundle),
            "wget": .protected,
        ]

        let summary = UpdateActionBarSummary(
            selectedCount: 3, visibleCount: 3, targets: targets, protection: protection
        )

        #expect(summary.protectedCount == 1)
        #expect(summary.protectionText == trf("%@ z automatycznym cofnięciem", "1"))
    }

    @Test func theUpdateButtonLivesInTheBarNotInTheHeader() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let results = try slice(view, from: "private var resultsView: some View", to: "private var updateRunOverlay")
        let bar = try slice(view, from: "private var actionBar: some View", to: "private var listColumn: some View")

        #expect(!results.contains("requestUpdate"), "the header reports the scan; it no longer acts")
        #expect(bar.contains("Button(action: requestUpdate)"))
        #expect(bar.contains(".disabled(!allowsUpdateRun)"))
        #expect(bar.contains("SelectionCheckbox("), "the list-wide checkbox moves into the bar")
        #expect(view.contains(".safeAreaInset(edge: .bottom, spacing: 0) { actionBar }"),
                "the bar stays under the list instead of scrolling away with it")
    }

    @Test func thePlanOpensFromTheBarAsASheet() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let bar = try slice(view, from: "private var actionBar: some View", to: "private var listColumn: some View")

        #expect(bar.contains("scan.showPlanPreview = true"))
        #expect(view.contains(".sheet(isPresented: $scan.showPlanPreview)"))
        #expect(!view.contains("WegaDisclosure(isExpanded: $scan.showPlanPreview)"),
                "the plan no longer pushes the list down from inside the screen")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> Substring {
        let lower = try #require(source.range(of: start)?.lowerBound, "missing anchor: \(start)")
        let upper = try #require(
            source.range(of: end, range: lower..<source.endIndex)?.lowerBound, "missing anchor: \(end)"
        )
        return source[lower..<upper]
    }
}
