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

        // ARCH-08 — a lane credits its own row through `creditUnit()` instead of reaching
        // for the tracker, because several rows now finish at once.
        #expect(run.contains("await runNpmUpgrade(name: name) if outcome.isSuccessful { creditUnit() }"),
                "an npm package that failed must not be counted as installed")
        #expect(run.contains("func creditUnit() { upgradeTracker?.completeUnits(1)"),
                "one credited row is one unit, whichever lane produced it")
        #expect(run.contains("upgradeTracker?.completeUnits(appStoreItems.count) "
                             + "upgradeProgress = upgradeTracker?.progress return (appStoreItems, nil)"),
                "a failed mas batch must credit nothing — it reports nothing per app")
        #expect(run.contains("brewCallFinished(succeeded: outcome.isSuccessful)"),
                "the brew call must report its real verdict, not an assumed success")
        #expect(run.contains("brewCallFinished(succeeded: false)"),
                "a brew call that threw must report failure")
    }

    /// `brew upgrade <names…>` also upgrades dependents nobody selected, so the tracker is
    /// told what the run asked for. Without that set the bar reached its total during the
    /// formula phase and never moved again.
    @Test func onlyTheTokensTheRunAskedBrewForMayBeCredited() throws {
        let run = compact(executableSource(try ScanStoreSources.everything()))

        #expect(run.contains("plannedTokens: Set(plan.formulaNames + plannedCaskNames)"),
                "the tracker must know which tokens this run planned")
    }

    /// npm and the App Store print nothing the tracker parses, so the run names what it is
    /// handing over — otherwise the label keeps naming a brew package that already finished,
    /// and a run with neither cask nor formula never leaves "preparing backups".
    @Test func theSourcesThatPrintNothingNameWhatTheyAreInstalling() throws {
        let run = compact(executableSource(try ScanStoreSources.everything()))

        #expect(run.contains("beginItem(named: name) defer { endItem() } let outcome = await runNpmUpgrade(name: name)"),
                "npm must name its package before that package starts installing")
        #expect(run.contains("beginItem(named: \"\")"),
                "the App Store batch must take the label over, naming no single app")
        // ARCH-08 — naming is now conditional: with several rows in flight, naming one of
        // them misdescribes the others, so the batch label takes over.
        #expect(run.contains("if inFlightItemCount > 1 { upgradeTracker?.beginInstallingBatch() } "
                             + "else { upgradeTracker?.beginInstalling(token: token) } "
                             + "upgradeProgress = upgradeTracker?.progress"),
                "the batch label must take over whenever a single name would misdescribe the run")
    }

    /// M2(c) deleted five invented command bars that animated on a timer while the real work
    /// happened elsewhere. This is the guard that keeps them deleted.
    @Test func nothingAnimatesProgressOnATimer() throws {
        for file in ["UpdateViewSupport.swift", "UpdateBandRunViews.swift"] {
            let bar = executableSource(try source("Sources/MacUpdater/\(file)"))

            #expect(!bar.contains("Timer"), "the progress must not run a timer: \(file)")
            #expect(!bar.contains("Task.sleep"), "the progress must not fabricate movement: \(file)")
        }
    }

    /// C2 stage 3 — the band carries the run while an update is running, and renders the
    /// store's progress rather than one of its own.
    @Test func theBandShowsTheRunOnlyWhileInstalling() throws {
        let view = executableSource(try source("Sources/MacUpdater/UpdateView.swift"))

        #expect(view.contains("run: scan.updating ? runPresentation : nil"),
                "the run appears in the band only while an update is running")
        #expect(compact(view).contains("UpdateBandRunPresentation( progress: scan.upgradeProgress,"),
                "and renders the store's value rather than one of its own")
    }

    /// The ring carries the progress now. The linear bar it replaced reported a nonzero
    /// intrinsic width that, unbounded, widened the detail column until the sidebar was
    /// pushed off-screen; no linear bar is left to do it.
    @Test func theRunDrawsNoLinearBar() throws {
        let support = executableSource(try source("Sources/MacUpdater/UpdateViewSupport.swift"))
        let runViews = executableSource(try source("Sources/MacUpdater/UpdateBandRunViews.swift"))

        #expect(!support.contains("struct UpgradeProgressBar"))
        #expect(!runViews.contains("ProgressView("))
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
