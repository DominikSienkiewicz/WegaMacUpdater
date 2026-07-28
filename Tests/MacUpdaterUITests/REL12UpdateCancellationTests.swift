import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// REL-12 — "Anuluj" for the foreground upgrade, and the guarantee that every external
/// command is bounded.
///
/// The store half is exercised directly; the wiring that cannot be driven without a live
/// Homebrew (which boundary the run checks, and which button calls it) is pinned by reading
/// the sources, the same way the architecture regressions do.
@Suite("REL-12 update cancellation")
@MainActor
struct REL12UpdateCancellationTests {

    // MARK: - Store behaviour

    @Test func cancellingWithNothingRunningRequestsNothing() {
        let scan = ScanStore()

        scan.cancelUpdate()

        #expect(!scan.updateInterruption.isRequested)
    }

    /// While an upgrade is running the request is *recorded*, not executed: the package
    /// manager keeps going until the run reaches its next boundary.
    @Test func cancellingARunningUpgradeRecordsTheRequestAndSkipsWhatIsLeft() {
        let scan = ScanStore()
        scan.updating = true

        scan.cancelUpdate()
        #expect(scan.updateInterruption.isRequested)

        let stopped = scan.shouldStopUpdate(before: ["cask:figma", "npm:eslint"])
        #expect(stopped)
        #expect(scan.updateInterruption.skippedKeys == ["cask:figma", "npm:eslint"])
        #expect(scan.updateInterruption.didSkipWork)
    }

    /// A previous cancellation may not leak into the next run — otherwise the upgrade after
    /// a cancelled one would stop at its very first boundary.
    @Test func aNewRunStartsWithACleanStopSwitch() {
        let scan = ScanStore()
        scan.updating = true
        scan.cancelUpdate()

        scan.resetUpdateInterruption()

        #expect(!scan.updateInterruption.isRequested)
        #expect(!scan.shouldStopUpdate(before: ["cask:figma"]))
        #expect(scan.updateInterruption.skippedKeys.isEmpty)
    }

    // MARK: - Wiring

    /// Every package boundary of the run asks whether it should stop: after the formula
    /// batch, before every npm package, and before the App Store batch.
    @Test func theUpgradeChecksForAStopRequestAtEveryPackageBoundary() throws {
        let actions = executableSource(try ScanStoreSources.everything())
        let boundaryChecks = actions.components(separatedBy: "shouldStopUpdate(before:").count - 1

        #expect(boundaryChecks >= 4, "the run must test the stop switch at each package boundary")
        #expect(actions.contains("reportInterruptedRun(upgraded:"),
                "an interrupted run must not be reported as a completed one")
    }

    @Test func theUpdatesScreenOffersTheStopButtonWhileUpgrading() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.contains("scan.cancelUpdate()"), "the Updates screen must expose Anuluj")
        #expect(view.contains("scan.updateInterruption.isRequested"),
                "the button must show that the stop was already asked for")
    }

    /// REL-12's third acceptance criterion, as a guard rather than a promise: no command in
    /// the app may be launched without a limit. `ProcessRequest` now defaults to a bounded
    /// policy, so the only way back to an unbounded wait is to ask for one explicitly.
    @Test func noCommandIsLaunchedWithoutATimeout() throws {
        let root = packageRoot()
        let sources = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"),
            includingPropertiesForKeys: nil
        )
        var offenders: [String] = []
        while let url = sources?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = executableSource(try String(contentsOf: url, encoding: .utf8))
            if text.contains("timeout: nil") || text.contains("idleTimeout: nil") {
                offenders.append(url.lastPathComponent)
            }
        }

        #expect(offenders.isEmpty, "unbounded process timeouts in: \(offenders.joined(separator: ", "))")
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
}
