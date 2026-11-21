import Testing
@testable import MacUpdaterCore

/// UXP-13 — the band counts vendor apps, not checks: an app has several checkers in flight at
/// once, and it counts as checked only when the last of them has come back.
///
/// Each `finish` is bound before it is checked: `#expect` cannot capture a mutating call.
@Suite("Manual scan progress")
struct ManualScanProgressTests {
    let a = InstallationIdentity(path: "/Applications/A.app"), b = InstallationIdentity(path: "/Applications/B.app")

    @Test func anAppCountsOnceItsLastCheckIsBack() {
        var tracker = ManualScanProgressTracker(checksPerApp: [a: 2, b: 1])
        #expect(tracker.progress == ManualScanProgress(checkedApps: 0, totalApps: 2))
        let firstOfA = tracker.finish(a)
        #expect(!firstOfA)
        let onlyOfB = tracker.finish(b)
        #expect(onlyOfB)
        let lastOfA = tracker.finish(a)
        #expect(lastOfA)
        #expect(tracker.progress == ManualScanProgress(checkedApps: 2, totalApps: 2))
    }

    @Test func unknownRepeatedOrEmptyAppsChangeNothing() {
        var tracker = ManualScanProgressTracker(checksPerApp: [a: 1, b: 0])
        #expect(tracker.progress.totalApps == 1)
        let unknown = tracker.finish(InstallationIdentity(path: "/Applications/Other.app"))
        #expect(!unknown)
        let once = tracker.finish(a)
        #expect(once)
        let again = tracker.finish(a)
        #expect(!again)
        #expect(tracker.progress.checkedApps == 1)
    }
}
