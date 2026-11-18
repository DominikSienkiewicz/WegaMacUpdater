import Combine
import Foundation
import MacUpdaterCore
import XCTest

@testable import WegaMacUpdater

/// UX-19 — a scan used to take the whole Updates screen away, list, header and action bar
/// included, unless it was the launch refresh. A scan the user starts with a result on screen
/// now runs in place like that refresh: the list stays, stood down, and the header reports
/// each source's phase. Only the first scan, with nothing to keep on screen, still gets the
/// full scanning scene.
@MainActor
final class ScanInPlaceTests: XCTestCase {
    private enum StubError: Error { case unexpected([String]) }

    private func idleRunner() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner { request in
            switch request.arguments {
            case ["update"]:
                return ProcessResult(exitCode: 0, stdout: "Already up-to-date", stderr: "")
            case ["list", "--cask", "-1"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
            case ["outdated"]:
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            case ["outdated", "-g", "--json"]:
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            default:
                throw StubError.unexpected(request.arguments)
            }
        }
    }

    func testAScanStartedOverAResultRunsInPlace() async {
        let harness = makeScanStoreRuntimeHarness(runner: idleRunner())
        harness.store.lastCheck = Date(timeIntervalSince1970: 1_700_000_000)
        harness.store.status = .results

        var published: [UpdateStatus] = []
        var refreshing: [Bool] = []
        let statusSubscription = harness.store.$status.sink { published.append($0) }
        let refreshSubscription = harness.store.$isRefreshing.sink { refreshing.append($0) }
        defer { statusSubscription.cancel(); refreshSubscription.cancel() }

        harness.store.startCheck()
        await harness.store.scanTask?.value

        XCTAssertFalse(published.contains(.checking), "the list must stay on screen for the whole scan")
        XCTAssertTrue(refreshing.contains(true), "the scan reports itself as running in place")
        XCTAssertFalse(harness.store.isRefreshing, "and the flag does not outlive it")
    }

    /// The contrast: with nothing on screen there is nothing to keep, so the first scan still
    /// takes the window with the full scanning scene.
    func testTheFirstScanStillTakesTheWindow() async {
        let harness = makeScanStoreRuntimeHarness(runner: idleRunner())

        var published: [UpdateStatus] = []
        let subscription = harness.store.$status.sink { published.append($0) }
        defer { subscription.cancel() }

        harness.store.startCheck()
        await harness.store.scanTask?.value

        XCTAssertTrue(published.contains(.checking))
    }

    func testThePhaseStripReportsEachSourceHonestly() {
        XCTAssertEqual(
            ScanPhaseStrip.steps(for: .running(.npm)).map(\.state),
            [.done, .done, .running, .pending]
        )
        XCTAssertEqual(
            ScanPhaseStrip.steps(for: .cancelled(at: .mas)).map(\.state),
            [.done, .stopped, .pending, .pending]
        )
        XCTAssertEqual(ScanPhaseStrip.steps(for: .finished).map(\.state), [.done, .done, .done, .done])
        XCTAssertEqual(
            ScanPhaseStrip.steps(for: nil).map(\.state), [.pending, .pending, .pending, .pending],
            "before the first phase lands, nothing is claimed"
        )
        XCTAssertEqual(
            ScanPhaseStrip.steps(for: nil).map(\.title),
            ["Homebrew", "App Store", "npm", tr("Producenci")]
        )
    }

    func testTheHeaderCarriesThePhasesAndTheOverlayOnlyStandsTheListDown() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let overlay = try source("Sources/MacUpdater/ScanBusyOverlay.swift")
        let overlayView = try XCTUnwrap(overlay.range(of: "struct ScanBusyOverlay: View").map { overlay[$0.lowerBound...] })

        XCTAssertTrue(view.contains("ScanPhaseStrip(progress: scan.progress)"))
        XCTAssertFalse(view.contains("refreshingStamp"), "the phases replace the one-line stamp")
        XCTAssertFalse(overlayView.contains("ScanProgressScene("), "no second scanning scene over the list")
        XCTAssertTrue(overlayView.contains(".background(.regularMaterial)"), "the list stays, stood down")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
