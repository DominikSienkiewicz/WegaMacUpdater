import AppKit
import Foundation
import MacUpdaterCore
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// UX-14 — a Homebrew row and a manually updated app's row laid out the same facts in two
/// ways: the manual row had no checkbox column, so its icon sat left of every other icon, it
/// put the version under the name instead of in the version column, and both rows repeated
/// the release notes the inspector already shows, so no two rows had the same height.
@Suite("Update row layout")
@MainActor
struct UpdateRowLayoutTests {
    @Test func bothRowKindsShareTheColumns() throws {
        let packageRow = try slice(
            try source("Sources/MacUpdater/SharedViews.swift"),
            from: "struct PackageRow: View", to: "// MARK: - Rollback badge"
        )
        let manualRows = try slice(
            try source("Sources/MacUpdater/UpdateViewSupport.swift"),
            from: "struct ManualUpdateSection: View", to: "struct ManualUpdateActionView: View"
        )

        for row in [packageRow, manualRows] {
            #expect(row.contains("UpdateRowColumns {"), "both rows place name and version through one layout")
            #expect(row.contains("} version: {"))
        }
        #expect(manualRows.contains("QueueHandoffMark()"),
                "a row Wega does not batch shows the hand-off mark in the queue column")
        #expect(!manualRows.contains("SelectionColumnSpacer()"))
    }

    @Test func theQueueColumnPlaceholderIsExactlyAsWideAsTheQueueCircle() {
        let width = NSHostingView(rootView: QueueColumnPlaceholder()).fittingSize.width
        #expect(width == WegaLayout.queueCircleSize)
    }

    @Test func aLongCaskVersionStaysOnOneLine() throws {
        let column = WegaLayout.versionColumnWidth
        let shortPair = height(VersionArrow(from: "1.0", to: "1.1").frame(width: column))
        let unshortenable = String(repeating: "1.", count: 30) + "0"
        for (from, to) in [
            ("6.6395.1,8fc566f7b97e371bae421fc79c260de86c6a4106", "6.28899.2,155ca43c0ad5a4bd5734795688543b65b464cf47"),
            (unshortenable, unshortenable + "1"),
        ] {
            #expect(height(VersionArrow(from: from, to: to).frame(width: column)) == shortPair,
                    "\(from) must not wrap inside the version column")
        }

        let arrow = try slice(
            try source("Sources/MacUpdater/SharedViews.swift"),
            from: "struct VersionArrow: View", to: "// MARK: - PackageRow"
        )
        #expect(arrow.contains(".help("), "the full versions stay reachable as a tooltip")
        #expect(arrow.contains(".truncationMode(.middle)"))
    }

    @Test func theInspectorKeepsTheFullVersions() throws {
        let inspector = try source("Sources/MacUpdater/InspectorPane.swift")
        #expect(inspector.contains("VersionArrow(from: info.from, to: info.to, emphasis: info.emphasis, style: .full)"))
    }

    private func height<Content: View>(_ view: Content) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    @Test func vendorCardsWithoutAPathShowTheHandoffMark() throws {
        for (file, anchor) in [
            ("Sources/MacUpdater/DockerDesktopUpdateActions.swift", "struct UnresolvedDockerUpdateRow: View"),
            ("Sources/MacUpdater/ServiceVendorUpdateControls.swift", "struct UnresolvedServiceUpdateRow: View"),
        ] {
            let text = try source(file)
            let start = try #require(text.range(of: anchor)?.lowerBound, "missing anchor: \(anchor)")
            #expect(text[start...].contains("QueueHandoffMark()"), "\(anchor) shows the hand-off mark")
        }
    }

    @Test func releaseNotesLiveOnlyInTheInspector() throws {
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let packageSection = try slice(support, from: "struct UpdateSection: View", to: "private struct UpdatePolicyMenu")
        let manualSection = try slice(
            support, from: "struct ManualUpdateSection: View", to: "struct ManualUpdateActionView: View"
        )

        for section in [packageSection, manualSection] {
            #expect(!section.contains("ReleaseNotesDisclosure("), "notes no longer unfold inside the list")
            #expect(!section.contains("CaskReleaseNotesView("))
        }
        let inspector = try source("Sources/MacUpdater/InspectorPane.swift")
        #expect(inspector.contains("CaskReleaseNotesView(request: request)"),
                "the inspector keeps fetching a cask's notes")
        #expect(inspector.contains("whatsNewContent(notes: app.releaseNotes)"),
                "and keeps showing a manual app's notes")
    }

    /// The row's disclosure fetched a feed's linked notes in the app and counted the releases
    /// it left out. With the disclosure gone from the list, the inspector has to do both, or
    /// moving the notes would quietly turn them into a bare link.
    @Test func theInspectorKeepsWhatTheRowDisclosureDid() throws {
        let inspector = try slice(
            try source("Sources/MacUpdater/InspectorPane.swift"),
            from: "private func whatsNewContent(notes: ReleaseNotes?)", to: "// MARK:"
        )

        #expect(inspector.contains("ReleaseNotesDisclosure(notes: notes, expanded: true)"),
                "a link-only note is fetched in the app, as the row did")
        #expect(inspector.contains("wcześniejszych wydań"),
                "and releases left out of the history are still counted")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func theHandoffMarkIsExactlyAsWideAsTheQueueCircle() {
        let circle = NSHostingView(
            rootView: Toggle(isOn: .constant(true)) { EmptyView() }.toggleStyle(WegaQueueToggleStyle())
        )
        let mark = NSHostingView(rootView: QueueHandoffMark())

        #expect(circle.fittingSize.width == WegaLayout.queueCircleSize)
        #expect(mark.fittingSize.width == circle.fittingSize.width)
    }

    @Test func everyQueueStateHasItsOwnGlyph() {
        #expect(QueueCircleState(SelectAllState.none) == .notQueued)
        #expect(QueueCircleState(SelectAllState.all) == .queued)
        #expect(QueueCircleState(SelectAllState.partial) == .partial)
        let states: [QueueCircleState] = [.notQueued, .queued, .partial, .handoff]
        #expect(Set(states.map(\.symbolName)).count == states.count)
        #expect(QueueCircleState.queued.symbolName == "checkmark")
        #expect(QueueCircleState.handoff.symbolName == "arrow.up.right")
    }

    @Test func theInspectedRowHasAnInkOutlineAndQueuedRowsStayUntinted() throws {
        let packageRow = try slice(
            try source("Sources/MacUpdater/SharedViews.swift"),
            from: "struct PackageRow: View", to: "// MARK: - Rollback badge"
        )
        let manualRows = try slice(
            try source("Sources/MacUpdater/UpdateViewSupport.swift"),
            from: "struct ManualUpdateSection: View", to: "struct ManualUpdateActionView: View"
        )
        for row in [packageRow, manualRows] {
            #expect(row.contains(".queueRowSelection(isInspected)"))
            #expect(!row.contains("Color.wegaHoney.opacity(0.05)"), "queued rows lose the honey tint")
            #expect(!row.contains("Color.wegaHoney.opacity(0.08)"), "the inspected row is lavender, not honey")
            #expect(!row.contains("Rectangle().fill(Color.wegaHoney).frame(width: 2)"))
        }
        let surface = try source("Sources/MacUpdater/QueueRowSurface.swift")
        for role in ["Color.wegaSelectionFill", "Color.wegaSelectionOutline", "Color.wegaSelectionLedge"] {
            #expect(surface.contains(role), "the surface draws with \(role)")
        }
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> Substring {
        let lower = try #require(source.range(of: start)?.lowerBound, "missing anchor: \(start)")
        let upper = try #require(
            source.range(of: end, range: lower..<source.endIndex)?.lowerBound, "missing anchor: \(end)"
        )
        return source[lower..<upper]
    }
}
