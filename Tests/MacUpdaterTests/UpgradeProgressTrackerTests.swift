import Testing
@testable import MacUpdaterCore

@Suite("UpgradeProgressTracker")
struct UpgradeProgressTrackerTests {

    @Test func startsAtZeroWhilePreparing() {
        let tracker = UpgradeProgressTracker(totalUnits: 3, plannedTokens: ["git", "node", "firefox"])

        #expect(tracker.progress.completedUnits == 0)
        #expect(tracker.progress.totalUnits == 3)
        #expect(tracker.progress.stage == .preparing)
        #expect(tracker.progress.fractionCompleted == 0)
    }

    /// A formula never announces its own completion, so the next package starting is what
    /// closes the previous one.
    @Test func theNextPackageClosesThePreviousOne() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: ["git", "node"])

        tracker.consume(chunk: "==> Upgrading git\n")
        #expect(tracker.progress.completedUnits == 0)

        tracker.consume(chunk: "==> Upgrading node\n")
        #expect(tracker.progress.completedUnits == 1)
        #expect(tracker.progress.stage == .installing(token: "node"))
    }

    /// A cask is announced twice — `==> Upgrading firefox` then `==> Installing Cask
    /// firefox`. The boundary rule must not read the second as the first one finishing.
    @Test func theSamePackageAnnouncedTwiceIsStillOnePackage() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: ["firefox"])

        tracker.consume(chunk: "==> Upgrading firefox\n==> Installing Cask firefox\n")

        #expect(tracker.progress.completedUnits == 0)
        #expect(tracker.progress.stage == .installing(token: "firefox"))
    }

    @Test func aCaskIsCreditedOnceDespiteBothItsSuccessLineAndTheBoundary() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: ["firefox", "iterm2"])

        tracker.consume(chunk: "==> Upgrading firefox\n")
        tracker.consume(chunk: "🍺  firefox was successfully upgraded!\n")
        tracker.consume(chunk: "==> Upgrading iterm2\n")

        #expect(tracker.progress.completedUnits == 1)
    }

    /// `brew upgrade <names…>` also upgrades the outdated dependents of what was asked for,
    /// announcing each with the same marker. Crediting those reaches the total while the
    /// packages the user selected are still waiting their turn.
    @Test func anUnplannedDependentIsNotCredited() {
        let tracker = UpgradeProgressTracker(totalUnits: 3, plannedTokens: ["openssl@3"])

        tracker.consume(chunk: "==> Upgrading openssl@3\n")
        tracker.consume(chunk: "==> Upgrading curl\n")
        tracker.consume(chunk: "==> Upgrading python@3.12\n")
        tracker.brewCallFinished(succeeded: true)

        #expect(tracker.progress.completedUnits == 1)
    }

    /// Brew names a formula by its tap where the plan holds the bare name, so the two are
    /// matched on the bare name — and `homebrew/core/node` and `node` count once, not twice.
    @Test func theTappedFormOfAPlannedPackageIsStillCredited() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: ["node", "git"])

        tracker.consume(chunk: "==> Upgrading homebrew/core/node\n")
        tracker.consume(chunk: "==> Upgrading git\n")

        #expect(tracker.progress.completedUnits == 1)
        #expect(tracker.progress.stage == .installing(token: "git"))
    }

    /// The `--force` retry runs tokens that were already counted. A bar that walks backwards
    /// reads as a bug, so the count is a set, not a running total.
    @Test func aForcedRetryDoesNotMoveTheCountBackwards() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: ["figma"])

        tracker.consume(chunk: "==> Upgrading figma\n🍺  figma was successfully upgraded!\n")
        #expect(tracker.progress.completedUnits == 1)

        tracker.consume(chunk: "==> Upgrading figma\n🍺  figma was successfully upgraded!\n")
        #expect(tracker.progress.completedUnits == 1)
    }

    @Test func aSuccessfulBrewCallCreditsThePackageStillInFlight() {
        let tracker = UpgradeProgressTracker(totalUnits: 1, plannedTokens: ["git"])

        tracker.consume(chunk: "==> Upgrading git\n")
        tracker.brewCallFinished(succeeded: true)

        #expect(tracker.progress.completedUnits == 1)
        #expect(tracker.progress.fractionCompleted == 1)
    }

    /// A run that failed part-way ends below 100%: the package brew died on is not finished
    /// work, and the bar reports finished work.
    @Test func aFailedBrewCallCreditsNothingItLeftUnfinished() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: ["git"])

        tracker.consume(chunk: "==> Upgrading git\n")
        tracker.brewCallFinished(succeeded: false)

        #expect(tracker.progress.completedUnits == 0)
    }

    @Test func npmAndMasAdvanceWithoutAnyParsedOutput() {
        let tracker = UpgradeProgressTracker(totalUnits: 4, plannedTokens: [])

        tracker.completeUnits(1)
        tracker.completeUnits(2)

        #expect(tracker.progress.completedUnits == 3)
    }

    /// npm prints nothing this tracker parses, so a run with no brew package at all would
    /// otherwise never leave `.preparing` — an indeterminate bar captioned with backups
    /// that were never taken.
    @Test func anNpmOnlyRunNamesThePackageItInstalls() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: [])

        tracker.beginInstalling(token: "typescript")
        #expect(tracker.progress.stage == .installing(token: "typescript"))
        #expect(tracker.progress.completedUnits == 0)

        tracker.completeUnits(1)
        #expect(tracker.progress.completedUnits == 1)
    }

    /// The App Store batch moves several apps behind one opaque call, so it names none.
    @Test func theAppStoreBatchNamesNoPackage() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: [])

        tracker.beginInstallingBatch()

        #expect(tracker.progress.stage == .installing(token: nil))
    }

    @Test func theCountNeverExceedsThePlannedTotal() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: [])

        tracker.completeUnits(99)

        #expect(tracker.progress.completedUnits == 2)
        #expect(tracker.progress.fractionCompleted == 1)
    }

    /// A single-package run is the one case where a download can be attributed without
    /// guessing: there is nothing else it could be.
    @Test func aSinglePackageRunNamesItsDownload() {
        let tracker = UpgradeProgressTracker(totalUnits: 1, plannedTokens: ["parallels"],
                                             soleDownloadToken: "parallels")

        tracker.consume(chunk: "==> Downloading https://cdn.example.com/Parallels.dmg\n")

        #expect(tracker.progress.stage == .downloading(token: "parallels"))
    }

    @Test func aBatchRunRefusesToNameWhatItIsDownloading() {
        let tracker = UpgradeProgressTracker(totalUnits: 3, plannedTokens: ["figma", "iterm2", "node"])

        tracker.consume(chunk: "==> Downloading https://cdn.example.com/Parallels.dmg\n")

        #expect(tracker.progress.stage == .downloading(token: nil))
    }

    /// A cask that fetches a resource after its install started: brew named the package one
    /// line earlier, so the download is not anonymous.
    @Test func aDownloadDuringAnInstallNamesThePackageInFlight() {
        let tracker = UpgradeProgressTracker(totalUnits: 3, plannedTokens: ["firefox", "iterm2"])

        tracker.consume(chunk: "==> Upgrading firefox\n")
        tracker.consume(chunk: "==> Downloading https://cdn.example.com/Firefox.dmg\n")

        #expect(tracker.progress.stage == .downloading(token: "firefox"))
    }

    @Test func brewNamingTheFormulaBeatsHavingNoNameAtAll() {
        let tracker = UpgradeProgressTracker(totalUnits: 3, plannedTokens: ["node"])

        tracker.consume(chunk: "==> Fetching downloads for: node\n")

        #expect(tracker.progress.stage == .downloading(token: "node"))
    }

    @Test func reportsTheFractionOfPackagesFinished() {
        let progress = UpgradeProgress(completedUnits: 3, totalUnits: 7, stage: .installing(token: "git"))

        #expect(abs(progress.fractionCompleted - 3.0 / 7.0) < 0.000_001)
    }

    @Test func anEmptyPlanHasNoFractionToReport() {
        let progress = UpgradeProgress(completedUnits: 0, totalUnits: 0, stage: .preparing)

        #expect(progress.fractionCompleted == 0)
    }

    /// Chunks arrive on pipe-read boundaries, so a marker routinely straddles two of them.
    @Test func aMarkerSplitAcrossTwoChunksIsStillRead() {
        let tracker = UpgradeProgressTracker(totalUnits: 1, plannedTokens: ["firefox"])

        tracker.consume(chunk: "==> Upgrading fire")
        tracker.consume(chunk: "fox\n")

        #expect(tracker.progress.stage == .installing(token: "firefox"))
    }

    /// A process's last line has no trailing newline; without a flush it would be lost.
    @Test func theLastLineWithoutANewlineIsStillRead() {
        let tracker = UpgradeProgressTracker(totalUnits: 2, plannedTokens: ["git", "node"])

        tracker.consume(chunk: "==> Upgrading git\n==> Upgrading node")
        tracker.brewCallFinished(succeeded: true)

        #expect(tracker.progress.completedUnits == 2)
    }
}
