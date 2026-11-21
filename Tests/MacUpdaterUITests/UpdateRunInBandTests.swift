import Foundation
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// While a batch installs, the Updates screen used to stay fully live: row checkboxes,
/// "Zaznacz wszystko", ignore/pin/skip, the manual "install" buttons, the banner's reinstall
/// action and the stale-cask card. Each either edits a selection the run already committed
/// to or starts a second package-manager operation mid-run. The list was only ever disabled
/// for a refresh (`allowsSelection(isRefreshing:)`), never for an update.
///
/// C2 stage 3 — the run used to stand the screen down under a veil with its bar at the bottom.
/// It now lives in the band above the list: the stage, the ring and the stop. Nothing lies on
/// the rows; `.disabled` alone keeps them inert, and the band and the run's log stay live
/// because they sit outside the disabled screen.
@Suite("Update run in the band")
@MainActor
struct UpdateRunInBandTests {
    @Test func theScreenIsInertForTheWholeRun() {
        #expect(ScanSelectionGate.allowsScreenInteraction(isUpdating: false))
        #expect(!ScanSelectionGate.allowsScreenInteraction(isUpdating: true),
                "a running update owns the screen until it lands")
    }

    @Test func theUpdatesScreenDisablesEverythingBelowTheHeaderWhileUpdating() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.contains(".disabled(!ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating))"),
                "rows, banner, plan preview, stale-cask card and manual installs must be inert during a run")
        #expect(!view.contains(".accessibilityHidden(scan.updating)"),
                "UXP-10: the list stays readable to VoiceOver during a run, only disabled")
    }

    @Test func theBandCarriesTheRunAndItsStopButton() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        #expect(view.contains("run: scan.updating ? runPresentation : nil"))
        #expect(view.contains("onStop: { scan.cancelUpdate() }") && view.contains("onShowLog: { scan.showLog = true }"))
        let controls = executableSource(try source("Sources/MacUpdater/UpdateBandRunViews.swift"))
        #expect(controls.contains(".disabled(run.isStopping)"), "a stop already requested cannot be requested twice")
        #expect(controls.contains(".help(UpdateRunCopy.stopHelp)"))
    }

    /// 0.8.0's veil of the window's own background kept the rows legible but still lay on them;
    /// C2 takes it away. The band and its run views draw no material or glass either.
    @Test func nothingLiesOnTheRowsDuringTheRun() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        let results = try slice(view, from: "private var resultsView: some View", to: "private var listHeader: some View")
        #expect(!results.contains(".overlay"), "no veil, card or material lies on the rows")
        #expect(!FileManager.default.fileExists(atPath: packageRoot().appendingPathComponent("Sources/MacUpdater/UpdateRunOverlay.swift").path))
        for file in ["UpdateBand.swift", "UpdateBandRunViews.swift", "UpdateBandSummaryViews.swift"] {
            let text = try source("Sources/MacUpdater/\(file)")
            #expect(!text.contains("Material") && !text.contains(".glassEffect("), "\(file)")
        }
    }

    /// The band comes before the disabled screen and the log after it, both outside
    /// `.disabled`: were either inside, the stop button or the log's close would be greyed out
    /// with the rows.
    @Test func theStopAndTheLogStayLiveOutsideTheDisabledScreen() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))
        let results = try slice(view, from: "private var resultsView: some View", to: "private var listHeader: some View")
        let band = try #require(results.range(of: "resultsBand"))
        let disabled = try #require(results.range(of: "screenBody\n                .disabled(!ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating))"))
        let log = try #require(results.range(of: "if scan.updating && scan.showLog {"))
        #expect(band.lowerBound < disabled.lowerBound && disabled.upperBound <= log.lowerBound)
        #expect(results.contains("BrewLogPanel(lines: scan.brewLog, onClose: { scan.showLog = false })"))
        let screen = try slice(view, from: "private var screenBody: some View", to: "private var scopeBar: some View")
        #expect(!screen.contains("resultsBand") && !screen.contains("BrewLogPanel(lines: scan.brewLog, onClose:"))
    }

    /// The stop button used to sit in the header next to "Zaktualizuj wybrane". Two stop
    /// buttons for one run is one too many.
    @Test func theHeaderNoLongerCarriesASecondStopButton() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.components(separatedBy: "scan.cancelUpdate()").count == 2,
                "exactly one call site: the band's stop")
    }

    // MARK: - Helpers

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private func executableSource(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> Substring {
        let lower = try #require(source.range(of: start)?.lowerBound, "missing anchor: \(start)")
        let upper = try #require(source.range(of: end, range: lower..<source.endIndex)?.lowerBound, "missing anchor: \(end)")
        return source[lower..<upper]
    }
}
