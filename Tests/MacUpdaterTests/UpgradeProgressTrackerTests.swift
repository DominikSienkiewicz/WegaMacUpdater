import Testing
@testable import MacUpdaterCore

@Suite("UpgradeProgressTracker")
struct UpgradeProgressTrackerTests {

    @Test func startsAtZeroWhilePreparing() {
        let tracker = UpgradeProgressTracker(totalUnits: 3)

        #expect(tracker.progress.completedUnits == 0)
        #expect(tracker.progress.totalUnits == 3)
        #expect(tracker.progress.stage == .preparing)
        #expect(tracker.progress.fractionCompleted == 0)
    }

    /// A formula never announces its own completion, so the next package starting is what
    /// closes the previous one.
    @Test func theNextPackageClosesThePreviousOne() {
        let tracker = UpgradeProgressTracker(totalUnits: 2)

        tracker.consume(chunk: "==> Upgrading git\n")
        #expect(tracker.progress.completedUnits == 0)

        tracker.consume(chunk: "==> Upgrading node\n")
        #expect(tracker.progress.completedUnits == 1)
        #expect(tracker.progress.stage == .installing(token: "node"))
    }

    /// A cask is announced twice — `==> Upgrading firefox` then `==> Installing Cask
    /// firefox`. The boundary rule must not read the second as the first one finishing.
    @Test func theSamePackageAnnouncedTwiceIsStillOnePackage() {
        let tracker = UpgradeProgressTracker(totalUnits: 2)

        tracker.consume(chunk: "==> Upgrading firefox\n==> Installing Cask firefox\n")

        #expect(tracker.progress.completedUnits == 0)
        #expect(tracker.progress.stage == .installing(token: "firefox"))
    }

    @Test func aCaskIsCreditedOnceDespiteBothItsSuccessLineAndTheBoundary() {
        let tracker = UpgradeProgressTracker(totalUnits: 2)

        tracker.consume(chunk: "==> Upgrading firefox\n")
        tracker.consume(chunk: "🍺  firefox was successfully upgraded!\n")
        tracker.consume(chunk: "==> Upgrading iterm2\n")

        #expect(tracker.progress.completedUnits == 1)
    }

    /// The `--force` retry runs tokens that were already counted. A bar that walks backwards
    /// reads as a bug, so the count is a set, not a running total.
    @Test func aForcedRetryDoesNotMoveTheCountBackwards() {
        let tracker = UpgradeProgressTracker(totalUnits: 2)

        tracker.consume(chunk: "==> Upgrading figma\n🍺  figma was successfully upgraded!\n")
        #expect(tracker.progress.completedUnits == 1)

        tracker.consume(chunk: "==> Upgrading figma\n🍺  figma was successfully upgraded!\n")
        #expect(tracker.progress.completedUnits == 1)
    }

    @Test func aSuccessfulBrewCallCreditsThePackageStillInFlight() {
        let tracker = UpgradeProgressTracker(totalUnits: 1)

        tracker.consume(chunk: "==> Upgrading git\n")
        tracker.brewCallFinished(succeeded: true)

        #expect(tracker.progress.completedUnits == 1)
        #expect(tracker.progress.fractionCompleted == 1)
    }

    /// A run that failed part-way ends below 100%: the package brew died on is not finished
    /// work, and the bar reports finished work.
    @Test func aFailedBrewCallCreditsNothingItLeftUnfinished() {
        let tracker = UpgradeProgressTracker(totalUnits: 2)

        tracker.consume(chunk: "==> Upgrading git\n")
        tracker.brewCallFinished(succeeded: false)

        #expect(tracker.progress.completedUnits == 0)
    }

    @Test func npmAndMasAdvanceWithoutAnyParsedOutput() {
        let tracker = UpgradeProgressTracker(totalUnits: 4)

        tracker.completeUnits(1)
        tracker.completeUnits(2)

        #expect(tracker.progress.completedUnits == 3)
    }

    @Test func theCountNeverExceedsThePlannedTotal() {
        let tracker = UpgradeProgressTracker(totalUnits: 2)

        tracker.completeUnits(99)

        #expect(tracker.progress.completedUnits == 2)
        #expect(tracker.progress.fractionCompleted == 1)
    }

    /// A single-package run is the one case where a download can be attributed without
    /// guessing: there is nothing else it could be.
    @Test func aSinglePackageRunNamesItsDownload() {
        let tracker = UpgradeProgressTracker(totalUnits: 1, soleDownloadToken: "parallels")

        tracker.consume(chunk: "==> Downloading https://cdn.example.com/Parallels.dmg\n")

        #expect(tracker.progress.stage == .downloading(token: "parallels"))
    }

    @Test func aBatchRunRefusesToNameWhatItIsDownloading() {
        let tracker = UpgradeProgressTracker(totalUnits: 3)

        tracker.consume(chunk: "==> Downloading https://cdn.example.com/Parallels.dmg\n")

        #expect(tracker.progress.stage == .downloading(token: nil))
    }

    @Test func brewNamingTheFormulaBeatsHavingNoNameAtAll() {
        let tracker = UpgradeProgressTracker(totalUnits: 3)

        tracker.consume(chunk: "==> Fetching downloads for: node\n")

        #expect(tracker.progress.stage == .downloading(token: "node"))
    }

    @Test func theRescanIsItsOwnStageAndCreditsNothing() {
        let tracker = UpgradeProgressTracker(totalUnits: 2)

        tracker.consume(chunk: "==> Upgrading git\n")
        tracker.beginRefreshing()

        #expect(tracker.progress.stage == .refreshing)
        #expect(tracker.progress.completedUnits == 0)
    }

    @Test func reportsTheFractionOfPackagesFinished() {
        let progress = UpgradeProgress(completedUnits: 3, totalUnits: 7, stage: .refreshing)

        #expect(abs(progress.fractionCompleted - 3.0 / 7.0) < 0.000_001)
    }

    @Test func anEmptyPlanHasNoFractionToReport() {
        let progress = UpgradeProgress(completedUnits: 0, totalUnits: 0, stage: .preparing)

        #expect(progress.fractionCompleted == 0)
    }
}
