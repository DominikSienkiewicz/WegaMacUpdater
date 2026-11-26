import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Cask replacements in the update queue") @MainActor
struct QueuedCaskReplacementTests {
    @Test func aSelectedCaskReplacementJoinsTheSamePlanAsAnOrdinaryUpdate() {
        let store = ScanStore()
        let app = makeApp()
        store.status = .results
        store.manualOutdated = [app]
        store.caskProfiles["test-queue-example"] = profile(artifact: app.path.lastPathComponent)
        store.brewOutdated = BrewOutdated(formulae: [
            BrewOutdatedItem(name: "example-tool", installedVersions: ["1"], currentVersion: "2")
        ], casks: [])
        let packageKey = UpdatePlanner.key(name: "example-tool", kind: .formula)
        let appKey = "m:" + app.path.path
        store.selected = [packageKey, appKey]

        #expect(Set(store.updateTargets(for: .all).map(\.key)) == [packageKey, appKey])
        #expect(store.updateTargets(for: .cli).map(\.key) == [packageKey])
        #expect(store.updateTargets(for: .apps).map(\.key) == [appKey])
    }

    @Test func vendorHandoffsAndMultipleCopiesNeverJoinTheQueue() {
        let store = ScanStore()
        let manual = makeApp()
        var second = manual
        second.path = URL(fileURLWithPath: "/Applications/Other/Queue Example.app")
        var vendor = manual
        vendor.source = .sparkle

        store.caskProfiles["test-queue-example"] = profile(artifact: manual.path.lastPathComponent)
        store.manualOutdated = [manual, second]
        store.selected = ["m:" + manual.path.path, "m:" + second.path.path]
        #expect(store.updateTargets(for: .all).isEmpty)

        store.manualOutdated = [vendor]
        #expect(store.updateTargets(for: .all).isEmpty)
    }

    @Test func anUnverifiedCaskDoesNotAppearSelectable() {
        let store = ScanStore()
        let app = makeApp()
        store.manualOutdated = [app]
        store.selected = ["m:" + app.path.path]

        #expect(store.updateTargets(for: .all).isEmpty)
        store.caskProfiles["test-queue-example"] = profile(artifact: "Another App.app")
        #expect(store.updateTargets(for: .all).isEmpty)
    }

    @Test func caskAdoptionAndRepairPinTheApprovedApplicationsDirectory() {
        let replacement = QueuedCaskReplacement(app: makeApp(), token: "test-queue-example")

        #expect(replacement.arguments(catalogVersion: "1.3,123", recordedVersion: nil) ==
                ["install", "--cask", "--force", "--appdir=/Applications", "--", replacement.token])
        #expect(replacement.arguments(catalogVersion: "1.3,123", recordedVersion: "1.3,123") ==
                ["reinstall", "--cask", "--appdir=/Applications", "--", replacement.token])
    }

    @Test func aCaskDestinationThatMovedOrHasTwoMatchesCannotReplaceTheApprovedApp() {
        let replacement = QueuedCaskReplacement(app: makeApp(), token: "test-queue-example")
        let userApplications = URL(fileURLWithPath: "/TestUser/Applications", isDirectory: true)
        let approvedRoot = replacement.directory
        let matchesBoth = CaskReplacementArtifactLocationResolver(
            applicationsDirectory: approvedRoot, userApplicationsDirectory: userApplications, fileExists: { _ in true }
        )
        let onlyUserCopy = CaskReplacementArtifactLocationResolver(
            applicationsDirectory: approvedRoot, userApplicationsDirectory: userApplications,
            fileExists: { $0.deletingLastPathComponent().path == userApplications.path }
        )
        let approvedCopy = CaskReplacementArtifactLocationResolver(
            applicationsDirectory: approvedRoot, userApplicationsDirectory: userApplications,
            fileExists: { $0.path == replacement.app.path.path }
        )

        #expect(!replacement.hasExactDestination(resolver: matchesBoth))
        #expect(!replacement.hasExactDestination(resolver: onlyUserCopy))
        #expect(replacement.hasExactDestination(resolver: approvedCopy))
    }

    @Test func selectAllDoesNotImplicitlyApproveACaskReplacement() {
        let store = ScanStore()
        let app = makeApp()
        store.status = .results
        store.manualOutdated = [app]
        store.caskProfiles["test-queue-example"] = profile(artifact: app.path.lastPathComponent)

        store.selectAllVisible(filter: .all)
        #expect(store.selected.isEmpty)
        store.toggleQueuedCaskReplacement(app)
        #expect(store.updateTargets(for: .all).map(\.key) == ["m:" + app.path.path])
    }

    @Test func onlyStillOfferedReplacementsBlockedByDiskStayQueued() {
        let store = ScanStore()
        let app = makeApp()
        let replacement = QueuedCaskReplacement(app: app, token: "test-queue-example")
        store.manualOutdated = [app]
        store.caskProfiles[replacement.token] = profile(artifact: app.path.lastPathComponent)
        let finishedKey = "f:already-updated"
        store.selected = [replacement.key, finishedKey]
        var row = ScanStore.LaneItemResult(item: replacement.item, outcome: nil)
        row.postponeReason = .insufficientDisk(required: 5_000_000_000, available: 2_000_000_000)

        store.finishReplacementSelection([row])
        #expect(store.selected == [replacement.key])
        #expect(store.banner?.action == .openCleanup(UpdateDiskBudget(required: 5_000_000_000, available: 2_000_000_000)))
        store.dismissBanner()

        store.manualOutdated = []
        store.finishReplacementSelection([row])
        #expect(store.selected.isEmpty)
        #expect(store.banner == nil)

        store.manualOutdated = [app]
        store.selected = [replacement.key]
        row.postponeReason = .diskSpaceUnknown
        store.finishReplacementSelection([row])
        #expect(store.selected.isEmpty)
        #expect(store.banner == nil)
    }

    private func profile(artifact: String) -> CaskArtifactProfile {
        CaskArtifactProfile(token: "test-queue-example", homepage: nil, artifacts: [
            CaskArtifact(kind: .app, names: [artifact])
        ])
    }

    private func makeApp() -> ManualOutdatedApp {
        ManualOutdatedApp(
            name: "Queue Example",
            path: URL(fileURLWithPath: "/Applications/Queue Example.app"),
            installedVersion: "1.2",
            availableVersion: "1.3",
            source: .cask(token: "test-queue-example"),
            bundleIdentifier: "com.example.wega.queue"
        )
    }
}
