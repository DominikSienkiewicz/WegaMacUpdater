import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

extension UninstallBundleFacts {
    static let userOwnedWritable = UninstallBundleFacts(
        ownerUID: 501, currentUserUID: 501, isWritableByUser: true, isTopLevelInApplications: true,
        hasBundleIdentifier: true, isAdministrator: true, helper: .notSupported
    )
    static let rootOwnedReadOnly = UninstallBundleFacts(
        ownerUID: 0, currentUserUID: 501, isWritableByUser: false, isTopLevelInApplications: true,
        hasBundleIdentifier: true, isAdministrator: true, helper: .notSupported
    )
    static let rootOwnedHelperEnabled = UninstallBundleFacts(
        ownerUID: 0, currentUserUID: 501, isWritableByUser: false, isTopLevelInApplications: true,
        hasBundleIdentifier: true, isAdministrator: true, helper: .enabled
    )
}

private struct TrashRefused: LocalizedError {
    var errorDescription: String? { "trash refused" }
}

/// Fails a test that reaches the helper when its route never should.
struct StagingNotExpected: Error {}

private struct StagingRequest: Equatable {
    let path: URL
    let bundleID: String
}

/// Records what the coordinator hands to the injected seams.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var leftovers: [URL] = []
    private var trashCalls: [URL] = []
    private var staging: [StagingRequest] = []

    func recordLeftovers(_ items: [URL]) {
        lock.lock(); defer { lock.unlock() }
        leftovers.append(contentsOf: items)
    }

    var trashedLeftovers: [URL] {
        lock.lock(); defer { lock.unlock() }
        return leftovers
    }

    func recordTrash(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        trashCalls.append(url)
    }

    var trashed: [URL] {
        lock.lock(); defer { lock.unlock() }
        return trashCalls
    }

    func recordStaging(_ path: URL, _ bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        staging.append(StagingRequest(path: path, bundleID: bundleID))
    }

    var stagingRequests: [StagingRequest] {
        lock.lock(); defer { lock.unlock() }
        return staging
    }
}

@MainActor
@Suite("Uninstall coordinator removal")
struct UninstallCoordinatorRemovalTests {
    private func app(_ name: String, brew: Bool = false) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: brew ? name.lowercased() : nil
        )
    }

    private func leftovers(for app: ApplicationInfo) -> LeftoverGroup {
        LeftoverGroup(app: app, items: [
            URL(fileURLWithPath: "/tmp/\(app.name)/Preferences.plist"),
            URL(fileURLWithPath: "/tmp/\(app.name)/Application Support"),
        ])
    }

    @Test func leftoversOfAFailedRemovalStayPut() async {
        let a = app("Alpha"), b = app("Bravo")
        let aLeftovers = leftovers(for: a), bLeftovers = leftovers(for: b)
        let recorder = Recorder()
        let failingPath = a.path
        let coordinator = UninstallCoordinator(dependencies: .init(
            uninstallCask: { _, _, _ in },
            trashItem: { url in if url == failingPath { throw TrashRefused() } },
            trashLeftovers: { items in
                recorder.recordLeftovers(items)
                return LeftoverCleanup.Result(removed: items)
            },
            protection: { _ in nil },
            runningApplications: { [] },
            requestQuit: { _ in false },
            forceKill: { _ in false },
            waitBetweenRunningChecks: {},
            bundleFacts: { _ in .userOwnedWritable },
            stageForTrash: { _, _ in throw StagingNotExpected() }
        ))

        let outcome = await coordinator.uninstall(
            targets: [a, b], zap: false, leftovers: [aLeftovers, bLeftovers], using: BrewService()
        )

        #expect(outcome.results[a.id] == .failed("trash refused"))
        #expect(outcome.results[b.id] == .movedToTrash)
        #expect(recorder.trashedLeftovers == bLeftovers.items)
        #expect(outcome.leftoversTrashed == bLeftovers.items.count)
    }

    private func coordinator(
        facts: UninstallBundleFacts,
        trash: @escaping @Sendable (URL) throws -> Void,
        trashLeftovers: @escaping @Sendable ([URL]) -> LeftoverCleanup.Result = { LeftoverCleanup.Result(removed: $0) },
        stage: @escaping @Sendable (URL, String) async throws -> URL = { _, _ in throw StagingNotExpected() }
    ) -> UninstallCoordinator {
        UninstallCoordinator(dependencies: .init(
            uninstallCask: { _, _, _ in },
            trashItem: trash,
            trashLeftovers: trashLeftovers,
            protection: { _ in nil },
            runningApplications: { [] },
            requestQuit: { _ in false },
            forceKill: { _ in false },
            waitBetweenRunningChecks: {},
            bundleFacts: { _ in facts },
            stageForTrash: stage
        ))
    }

    @Test func blockedTargetIsNotAttempted() async {
        let target = app("Root")
        let calls = CallCounter()
        let sut = coordinator(facts: .rootOwnedReadOnly, trash: { _ in calls.increment() })

        let outcome = await sut.uninstall(targets: [target], zap: false, using: BrewService())

        #expect(calls.count == 0)
        #expect(outcome.results[target.id] == .blocked(.needsAdministratorRights))
    }

    @Test func routesPreflightOnlyNonBrewTargets() {
        let manual = app("Manual"), cask = app("Cask", brew: true)
        let sut = coordinator(facts: .rootOwnedReadOnly, trash: { _ in })

        let routes = sut.routes(for: [manual, cask])

        #expect(routes[manual.id] == .blocked(.needsAdministratorRights))
        #expect(routes[cask.id] == nil)
    }

    @Test func userOwnedPermissionDeniedIsAppManagement() async {
        let target = app("Mine")
        let denied = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        let sut = coordinator(facts: .userOwnedWritable, trash: { _ in throw denied })

        let outcome = await sut.uninstall(targets: [target], zap: false, using: BrewService())

        #expect(outcome.results[target.id] == .blocked(.needsAppManagement))
    }

    @Test func missingBundleIsFailedAndKeepsLeftovers() async {
        let target = app("Gone")
        let recorder = Recorder()
        let missing = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
        let sut = coordinator(
            facts: .userOwnedWritable,
            trash: { _ in throw missing },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) }
        )

        let outcome = await sut.uninstall(
            targets: [target], zap: false, leftovers: [leftovers(for: target)], using: BrewService()
        )

        guard case .failed = outcome.results[target.id] else {
            Issue.record("expected .failed, got \(String(describing: outcome.results[target.id]))")
            return
        }
        #expect(recorder.trashedLeftovers.isEmpty)
        #expect(outcome.leftoversTrashed == 0)
    }

    @Test func vanishedBundleWithLiveFactsIsFailedNotBlocked() async {
        let target = app("Vanished")
        let facts = UninstallBundleFacts.live(
            path: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Vanished.app"),
            hasBundleIdentifier: true,
            helper: .enabled
        )
        let missing = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
        let calls = CallCounter()
        let sut = coordinator(facts: facts, trash: { _ in calls.increment(); throw missing })

        let outcome = await sut.uninstall(targets: [target], zap: false, using: BrewService())

        #expect(calls.count == 1)
        guard case .failed = outcome.results[target.id] else {
            Issue.record("expected .failed, got \(String(describing: outcome.results[target.id]))")
            return
        }
    }

    // MARK: - Removal through Wega's helper (spec 4.3)

    private func stagedURL(for app: ApplicationInfo) -> URL {
        URL(fileURLWithPath: "/Library/Application Support/com.wega.WegaMacUpdater/UninstallStaging/\(UUID().uuidString)/\(app.name).app")
    }

    private func permissionDenied() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
    }

    /// A root-owned app the user cannot move goes to Wega's helper, which stages it; the app then
    /// moves the staged bundle to the Trash as the user, and the app's leftovers follow it.
    @Test func rootOwnedAppGoesThroughHelper() async {
        let target = app("Root")
        let original = target.path, staged = stagedURL(for: target), denied = permissionDenied()
        let recorder = Recorder()
        let sut = coordinator(
            facts: .rootOwnedHelperEnabled,
            trash: { url in
                recorder.recordTrash(url)
                if url == original { throw denied }
            },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) },
            stage: { path, bundleID in
                recorder.recordStaging(path, bundleID)
                return staged
            }
        )

        let outcome = await sut.uninstall(
            targets: [target], zap: false, leftovers: [leftovers(for: target)], using: BrewService()
        )

        #expect(outcome.results[target.id] == .movedToTrashByHelper)
        #expect(recorder.stagingRequests == [StagingRequest(path: original, bundleID: "com.example.root")])
        #expect(recorder.trashed.last == staged)
        #expect(recorder.trashedLeftovers == leftovers(for: target).items)
    }

    /// The helper moved the app out of /Applications but the Trash refused the staged bundle: it
    /// stays where the helper put it, and the app's leftovers stay too.
    @Test func stagedBundleThatCannotBeTrashedIsLeftInStaging() async {
        let target = app("Root")
        let original = target.path, staged = stagedURL(for: target), denied = permissionDenied()
        let recorder = Recorder()
        let sut = coordinator(
            facts: .rootOwnedHelperEnabled,
            trash: { url in
                recorder.recordTrash(url)
                throw url == original ? denied : TrashRefused()
            },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) },
            stage: { _, _ in staged }
        )

        let outcome = await sut.uninstall(
            targets: [target], zap: false, leftovers: [leftovers(for: target)], using: BrewService()
        )

        #expect(outcome.results[target.id] == .leftInStaging(staged))
        #expect(recorder.trashed == [original, staged])
        #expect(recorder.trashedLeftovers.isEmpty)
        #expect(outcome.leftoversTrashed == 0)
    }

    /// A helper that is off, or older than this app (protocol 5), reads as "needs Wega's helper".
    @Test(arguments: [
        PrivilegedHelperClient.HelperError.notEnabled,
        .versionMismatch(helper: "5", expected: WegaHelper.version),
    ])
    func staleHelperReadsAsNeedsHelper(_ error: PrivilegedHelperClient.HelperError) async {
        let target = app("Root")
        let denied = permissionDenied()
        let recorder = Recorder()
        let sut = coordinator(
            facts: .rootOwnedHelperEnabled,
            trash: { _ in throw denied },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) },
            stage: { _, _ in throw error }
        )

        let outcome = await sut.uninstall(
            targets: [target], zap: false, leftovers: [leftovers(for: target)], using: BrewService()
        )

        #expect(outcome.results[target.id] == .blocked(.needsHelper))
        #expect(recorder.trashedLeftovers.isEmpty)
    }

    @Test func helperErrorIsFailedWithItsMessage() async {
        let target = app("Root")
        let denied = permissionDenied()
        let recorder = Recorder()
        let sut = coordinator(
            facts: .rootOwnedHelperEnabled,
            trash: { _ in throw denied },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) },
            stage: { _, _ in throw PrivilegedHelperClient.HelperError.operationFailed("Aplikacja nie należy do roota.") }
        )

        let outcome = await sut.uninstall(
            targets: [target], zap: false, leftovers: [leftovers(for: target)], using: BrewService()
        )

        #expect(outcome.results[target.id] == .failed("Aplikacja nie należy do roota."))
        #expect(recorder.trashedLeftovers.isEmpty)
    }

    /// Once the request may have reached the helper, a timeout or a lost connection does not say
    /// the removal failed: the app may already be out of /Applications. Nothing else is touched.
    @Test(arguments: [PrivilegedHelperClient.HelperError.timedOut, .connectionFailed])
    func unconfirmedStagingSaysTheAppMayAlreadyHaveLeft(_ error: PrivilegedHelperClient.HelperError) async {
        let target = app("Root")
        let original = target.path, denied = permissionDenied()
        let recorder = Recorder()
        let sut = coordinator(
            facts: .rootOwnedHelperEnabled,
            trash: { url in
                recorder.recordTrash(url)
                throw denied
            },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) },
            stage: { _, _ in throw error }
        )

        let outcome = await sut.uninstall(
            targets: [target], zap: false, leftovers: [leftovers(for: target)], using: BrewService()
        )

        let message = UninstallCoordinator.unconfirmedHelperRemoval
        #expect(outcome.results[target.id] == .failed(message))
        #expect(message.contains("/Applications"))
        #expect(message != error.localizedDescription)
        #expect(recorder.trashed == [original])
        #expect(recorder.trashedLeftovers.isEmpty)
        #expect(outcome.leftoversTrashed == 0)
    }

    @Test func helperRouteIsPreflightedForTheSheet() {
        let target = app("Root")
        let sut = coordinator(facts: .rootOwnedHelperEnabled, trash: { _ in })

        #expect(sut.routes(for: [target])[target.id] == .helper)
    }

    @Test func brewTargetReportsRemovedByHomebrew() async {
        let cask = app("Charlie", brew: true)
        let coordinator = UninstallCoordinator(dependencies: .init(
            uninstallCask: { _, _, _ in },
            trashItem: { _ in },
            trashLeftovers: { LeftoverCleanup.Result(removed: $0) },
            protection: { _ in nil },
            runningApplications: { [] },
            requestQuit: { _ in false },
            forceKill: { _ in false },
            waitBetweenRunningChecks: {},
            bundleFacts: { _ in .userOwnedWritable },
            stageForTrash: { _, _ in throw StagingNotExpected() }
        ))

        let outcome = await coordinator.uninstall(
            targets: [cask], zap: true, leftovers: [], using: BrewService()
        )

        #expect(outcome.results[cask.id] == .removedByHomebrew)
    }

    private func process(_ app: ApplicationInfo, pid: Int32) -> RunningApplicationTarget {
        RunningApplicationTarget(
            processIdentifier: pid,
            bundleURL: app.path,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            processName: app.name
        )
    }

    private func coordinator(
        running: [RunningApplicationTarget],
        trashCalls: CallCounter,
        caskCalls: CallCounter,
        recorder: Recorder
    ) -> UninstallCoordinator {
        UninstallCoordinator(dependencies: .init(
            uninstallCask: { _, _, _ in caskCalls.increment() },
            trashItem: { _ in trashCalls.increment() },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) },
            protection: { _ in nil },
            runningApplications: { running },
            requestQuit: { _ in false },
            forceKill: { _ in false },
            waitBetweenRunningChecks: {},
            bundleFacts: { _ in .userOwnedWritable },
            stageForTrash: { _, _ in throw StagingNotExpected() }
        ))
    }

    /// The force-quit sheet and the write lease can both wait; an app relaunched meanwhile is
    /// running again by the time its bundle would go, so it is skipped with its leftovers.
    @Test func targetRunningAgainAtRemovalIsSkippedWithItsLeftovers() async {
        let manual = app("Manual"), cask = app("Cask", brew: true)
        let trashCalls = CallCounter(), caskCalls = CallCounter(), recorder = Recorder()
        let sut = coordinator(
            running: [process(manual, pid: 10), process(cask, pid: 20)],
            trashCalls: trashCalls, caskCalls: caskCalls, recorder: recorder
        )

        let outcome = await sut.uninstall(
            targets: [manual, cask], zap: false, leftovers: [leftovers(for: manual)], using: BrewService()
        )

        #expect(outcome.results[manual.id] == .skippedStillRunning)
        #expect(outcome.results[cask.id] == .skippedStillRunning)
        #expect(trashCalls.count == 0)
        #expect(caskCalls.count == 0)
        #expect(recorder.trashedLeftovers.isEmpty)
    }

    @Test func targetAmbiguousAtRemovalIsSkipped() async {
        let manual = app("Manual")
        let trashCalls = CallCounter(), caskCalls = CallCounter(), recorder = Recorder()
        let sut = coordinator(
            running: [process(manual, pid: 10), process(manual, pid: 11)],
            trashCalls: trashCalls, caskCalls: caskCalls, recorder: recorder
        )

        let outcome = await sut.uninstall(
            targets: [manual], zap: false, leftovers: [leftovers(for: manual)], using: BrewService()
        )

        #expect(outcome.results[manual.id] == .skippedAmbiguousProcess)
        #expect(trashCalls.count == 0)
        #expect(recorder.trashedLeftovers.isEmpty)
    }

    @Test func protectedTargetIsRefused() async {
        let safari = app("Safari")
        let trashCalls = CallCounter()
        let coordinator = UninstallCoordinator(dependencies: .init(
            uninstallCask: { _, _, _ in },
            trashItem: { _ in trashCalls.increment() },
            trashLeftovers: { LeftoverCleanup.Result(removed: $0) },
            protection: { _ in .systemApplication },
            runningApplications: { [] },
            requestQuit: { _ in false },
            forceKill: { _ in false },
            waitBetweenRunningChecks: {},
            bundleFacts: { _ in .userOwnedWritable },
            stageForTrash: { _, _ in throw StagingNotExpected() }
        ))

        let outcome = await coordinator.uninstall(
            targets: [safari], zap: false, leftovers: [leftovers(for: safari)], using: BrewService()
        )

        #expect(trashCalls.count == 0)
        #expect(outcome.results[safari.id] == .protected(.systemApplication))
        #expect(outcome.leftoversTrashed == 0)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.lock(); value += 1; lock.unlock() }

    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
