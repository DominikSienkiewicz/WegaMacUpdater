import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// The progress bar's wiring: the counter is fed from the stream that is already flowing,
/// it is cleared on every exit path, and nothing invents movement on a timer.
@Suite("Install progress wiring")
@MainActor
struct InstallProgressWiringTests {

    @Test func aStoreThatIsNotUpdatingReportsNoProgress() {
        let scan = ScanStore()

        #expect(scan.upgradeProgress == nil)
    }

    @Test func theRunFeedsTheCounterFromTheBrewOutputItAlreadyStreams() throws {
        let run = executableSource(try ScanStoreSources.everything())

        #expect(run.contains("UpgradeProgressTracker("),
                "the run must own one tracker")
        #expect(run.contains("upgradeTracker?.consume(chunk:"),
                "progress must come from the streamed brew output")
        #expect(run.contains("ProcessEventStream.drain"),
                "and from the one shared streaming loop, not a second one")
    }

    /// Every exit path — the stop switch, a publisher veto, a thrown error — must leave the
    /// bar gone, or a finished run keeps a bar on screen forever.
    @Test func theRunClearsTheBarOnEveryExitPath() throws {
        let run = compact(executableSource(try ScanStoreSources.everything()))

        #expect(run.contains("defer { upgradeProgress = nil upgradeTracker = nil }"),
                "clearing must be a defer, not a line each early return remembers")
        #expect(run.contains("upgradeProgress = nil"))
        #expect(run.contains("upgradeTracker = nil"))
    }

    @Test func sourcesThatReportNothingPerPackageAdvanceOnlyOnSuccess() throws {
        let run = compact(executableSource(try ScanStoreSources.everything()))

        #expect(run.contains("if outcome.isSuccessful { tracker.completeUnits(1)"),
                "an npm package that failed must not be counted as installed")
        #expect(run.contains("if masFailure == nil { tracker.completeUnits("),
                "a failed mas batch must credit nothing — it reports nothing per app")
        #expect(run.contains("brewCallFinished(succeeded: outcome.isSuccessful)"),
                "the brew call must report its real verdict, not an assumed success")
        #expect(run.contains("brewCallFinished(succeeded: false)"),
                "a brew call that threw must report failure")
    }

    /// M2(c) deleted five invented command bars that animated on a timer while the real work
    /// happened elsewhere. This is the guard that keeps them deleted.
    @Test func nothingAnimatesProgressOnATimer() throws {
        let bar = executableSource(try source("Sources/MacUpdater/UpdateViewSupport.swift"))

        #expect(!bar.contains("Timer"), "the bar must not run a timer")
        #expect(!bar.contains("Task.sleep"), "the bar must not fabricate movement")
    }

    @Test func theUpdatesScreenShowsTheBarOnlyWhileInstalling() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.contains("if scan.updating, let progress = scan.upgradeProgress"),
                "the bar appears only while an update is running")
        #expect(view.contains("UpgradeProgressBar(progress: progress)"),
                "and renders the store's value rather than one of its own")
    }

    /// A linear ProgressView reports a nonzero intrinsic width; with no upper bound it
    /// widens the detail column until the sidebar is pushed off-screen.
    @Test func theBarIsPinnedElasticSoItCannotShoveTheSidebarOffScreen() throws {
        let bar = executableSource(try source("Sources/MacUpdater/UpdateViewSupport.swift"))

        #expect(bar.contains("struct UpgradeProgressBar"))
        #expect(bar.contains("frame(minWidth: 0, maxWidth: .infinity)"))
    }

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

    /// Collapses whitespace so a guard can assert on a code shape without pinning the
    /// indentation it happens to be written at.
    private func compact(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
