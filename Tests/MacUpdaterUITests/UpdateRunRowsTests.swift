import AppKit
import Foundation
import SwiftUI
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Run status on the rows") @MainActor
struct UpdateRunRowsTests {
    private let statuses: [UpdateRunRowStatus] = [.waiting, .installing, .installedChecking, .failed, .notStarted]

    /// The chip takes the version's place, so it may never be wider than the column the version already owns.
    @Test func everyChipFitsTheVersionColumn() {
        for language in [AppLanguage.pl, .en] {
            for status in statuses {
                for stopping in [false, true] {
                    let width = withLanguage(language) {
                        NSHostingView(rootView: UpdateRunStatusChip(status: status, isStopping: stopping).fixedSize()).fittingSize.width
                    }
                    #expect(width <= WegaLayout.versionColumnWidth, "\(language) \(status) stopping \(stopping): \(width) pt")
                    #expect(width > 0, "\(language) \(status) stopping \(stopping) draws nothing")
                }
            }
        }
    }

    @Test func aRowKeepsItsHeightWhenTheRunNamesItsStatus() {
        for language in [AppLanguage.pl, .en] {
            for width in [360, 420, 520, 820] as [CGFloat] {
                withLanguage(language) {
                    let idle = NSHostingView(rootView: row(nil).frame(width: width)).fittingSize.height
                    for status in statuses {
                        let running = NSHostingView(rootView: row(status).frame(width: width)).fittingSize.height
                        #expect(running == idle, "\(language) width \(width), \(status): \(running) pt, idle \(idle) pt")
                    }
                }
            }
        }
    }

    /// A batch's state on its group header is state text: `.secondary`, one line, the full text
    /// in the tooltip, so the header keeps its height and the rows under it never move mid-run.
    @Test func aLaneNoteKeepsTheGroupHeaderHeight() {
        let headers = [
            HeaderSample(title: "Narzędzia CLI", ordinal: 3), HeaderSample(title: "Aplikacje", ordinal: 2),
            HeaderSample(title: "Narzędzia Homebrew", subtitle: "narzędzia CLI"),
            HeaderSample(title: "Mac App Store", subtitle: "via mas-cli"),
        ]
        for language in [AppLanguage.pl, .en] {
            withLanguage(language) {
                let notes = laneNotes()
                for width in [368, 420] as [CGFloat] {
                    for header in headers {
                        let idle = headerHeight(header, runNote: nil, width: width)
                        for note in notes {
                            let running = headerHeight(header, runNote: note, width: width)
                            #expect(running == idle, "\(language) \(width) pt \(header.title) „\(note)”: \(running) pt, idle \(idle) pt")
                        }
                    }
                }
            }
        }
    }

    @Test func theLaneNoteIsSecondaryOnOneLineWithTheWholeTextInItsTooltip() throws {
        let header = try source("Sources/MacUpdater/UpdateGroupHeader.swift")
        let row = try slice(header, from: "private var headerRow: some View", to: "Spacer()")
        let note = try slice(row, from: "if let runNote {", to: "} else if let note {")
        #expect(note.contains(".foregroundStyle(.secondary)"))
        #expect(note.contains(".lineLimit(1)"))
        #expect(note.contains(".help(runNote)"))
        #expect(!note.contains(".tertiary"))
    }

    @Test func theRowSpeaksItsRunStatusOnceInItsLabel() {
        withLanguage(.en) {
            let label = PackageRowAccessibility.label(name: "Slack", from: "1", to: "2", run: "installing…", isQueued: true)
            #expect(label == "Slack, update 1 to 2, installing…, queued")
        }
        withLanguage(.pl) {
            let idle = PackageRowAccessibility.label(name: "Slack", from: "1", to: "2", isQueued: true)
            #expect(!idle.contains("instaluję"))
        }
    }

    @Test func theBoardDimsNothingBeforeTheRunHasStarted() {
        let state = UpdateRunListState(board: .idle, isStopping: false)
        #expect(!state.isDimmed("c:any"))
    }

    @Test func theListPassesTheRunToItsSectionsAndTheyDrawIt() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let screen = try slice(view, from: "private var screenBody: some View", to: "private var scopeBar: some View")
        #expect(screen.contains(".environment(\\.updateRun, runListState)"))
        #expect(view.contains("scan.updating ? UpdateRunListState(board: scan.runBoard, isStopping: scan.updateInterruption.isRequested) : nil"))
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let section = try slice(support, from: "struct UpdateSection: View", to: "private struct UpdatePolicyMenu: View")
        #expect(section.contains("@Environment(\\.updateRun) private var run"))
        #expect(section.contains("note: subtitle, runNote: run?.laneNote(for: Set(items.map(\\.kind)))"))
        #expect(section.contains("runStatus: run?.rowStatus(for: item)"))
        #expect(section.contains(".opacity(run?.isDimmed(item.key) == true ? 0.55 : 1)"))
        let manual = try slice(support, from: "struct ManualUpdateSection: View", to: "struct ManualUpdateActionView: View")
        #expect(manual.contains("note: run != nil ? tr(\"u producenta\") : subtitle"))
        withLanguage(.en) { #expect(tr("u producenta") == "with the vendor") }
        let row = try slice(try source("Sources/MacUpdater/SharedViews.swift"), from: "struct PackageRow: View", to: "// MARK: - Rollback badge")
        #expect(row.contains("UpdateRunStatusChip(status: runStatus, isStopping: runIsStopping)"))
    }

    @Test func theChipStopsSpinningUnderReduceMotion() throws {
        let chip = try source("Sources/MacUpdater/UpdateRunStatusChip.swift")
        #expect(chip.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        let spinner = try #require(chip.range(of: "ProgressView()"))
        #expect(chip[chip.startIndex..<spinner.lowerBound].suffix(160).contains("reduceMotion"))
    }

    /// Every note a header can show for both batches at once, the longest there is, and for
    /// each batch alone.
    private func laneNotes() -> [String] {
        var notes: [String] = []
        for status in statuses {
            for stopping in [false, true] {
                let state = UpdateRunListState(
                    board: UpdateRunBoard(startedAt: Date(timeIntervalSince1970: 0), lanes: [.formulae: status, .appStore: status]),
                    isStopping: stopping
                )
                notes += [[.formula, .appStore], [.formula, .npm], [.cask, .appStore]].compactMap { state.laneNote(for: $0) }
            }
        }
        return notes
    }

    private struct HeaderSample {
        var title: String
        var ordinal: Int?
        var subtitle: String?
    }

    private func headerHeight(_ header: HeaderSample, runNote: String?, width: CGFloat) -> CGFloat {
        let view = UpdateGroupHeader(
            title: tr(header.title), tint: .wegaInfo, ordinal: header.ordinal, count: 12,
            note: header.subtitle.map { tr($0) }, runNote: runNote,
            selection: SelectionCheckbox(state: .partial, accessibilityLabel: "", accessibilityValue: "", toggle: {})
        )
        return NSHostingView(rootView: view.frame(width: width)).fittingSize.height
    }

    private func row(_ status: UpdateRunRowStatus?) -> PackageRow {
        PackageRow(name: "Visual Studio Code", token: "visual-studio-code", currentVersion: "1.95.3",
                   latestVersion: "1.96.0", isSelected: true, rollback: .protected, runStatus: status, onToggle: {})
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ text: String, from: String, to: String) throws -> String {
        let start = try #require(text.range(of: from))
        let region = text[start.lowerBound...]
        let end = try #require(region.range(of: to))
        return String(region[..<end.lowerBound])
    }
}
