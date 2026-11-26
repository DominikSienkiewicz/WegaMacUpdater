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
            LeftoverItem(url: URL(fileURLWithPath: "/tmp/\(app.name)/Preferences.plist"), source: .bundleIdentifier),
            LeftoverItem(url: URL(fileURLWithPath: "/tmp/\(app.name)/Application Support"), source: .bundleIdentifier),
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
        #expect(recorder.trashedLeftovers == bLeftovers.items.map(\.url))
        #expect(outcome.leftoversTrashed == bLeftovers.items.count)
    }

    @Test func resultsExcludeAbsentFilesFromTrashCount() async {
        let target = app("Fixture")
        let missing = URL(filePath: "/fixture/already-absent")
        let group = LeftoverGroup(app: target, items: [LeftoverItem(url: missing, source: .bundleIdentifier)])
        let sut = coordinator(
            facts: .userOwnedWritable,
            trash: { _ in },
            trashLeftovers: { files in
                LeftoverCleanup.removeToTrash(files, trash: { _ in throw TrashRefused() }, lstat: { _ in nil })
            }
        )

        let outcome = await sut.uninstall(targets: [target], zap: false, leftovers: [group], using: BrewService())

        #expect(outcome.leftoversTrashed == 0)
    }

    @Test func fileReportKeepsTheOutcomeAndRecoveryActionForEverySelectedPath() async throws {
        let target = app("Fixture"), skipped = app("Skipped")
        let moved = URL(filePath: "/fixture/moved"), missing = URL(filePath: "/fixture/missing")
        let locked = URL(filePath: "/fixture/locked"), shared = URL(filePath: "/fixture/shared")
        let items = [moved, missing, locked].map { LeftoverItem(url: $0, source: .bundleIdentifier) }
        let group = LeftoverGroup(app: target, items: items + [
            LeftoverItem(url: shared, source: .bundleIdentifier, coTargets: [skipped.id])
        ])
        let sut = coordinator(
            facts: .userOwnedWritable,
            trash: { _ in },
            trashLeftovers: { urls in
                LeftoverCleanup.removeToTrash(urls, trash: { url in
                    if url == locked { throw TrashRefused() }
                }, lstat: { url in
                    guard url != missing else { return nil }
                    return CleanupEntry(url: url, kind: .file, isExecutable: false,
                                        identity: .init(device: 1, inode: 1), modificationDate: nil)
                })
            }
        )
        let outcome = await sut.uninstall(
            targets: [target], zap: false, leftovers: [group, leftovers(for: skipped)],
            skipped: [skipped.id: .skippedStillRunning], using: BrewService()
        )
        let report = UninstallResultPresentation.report(
            results: outcome.results, apps: [target, skipped], files: outcome.files
        )
        #expect(outcome.files.map(\.url) == [moved, missing, locked, shared] + leftovers(for: skipped).items.map(\.url))
        #expect(outcome.files.map(\.status) == [
            .movedToTrash, .alreadyAbsent, .failed("trash refused"), .keptForAnotherApp,
            .keptForApp(skipped.name), .keptForApp(skipped.name)
        ])
        #expect(report.offersOpenTrash)
        #expect(report.files.first(where: { $0.url == locked })?.action == .showInFinder(locked))
        #expect(report.files.first(where: { $0.url == shared })?.action == .showInFinder(shared))
        #expect(try #require(report.files.first { $0.url == missing }).action == nil)

        let onlyMissing = UninstallResultPresentation.report(
            results: [:], apps: [], files: [UninstallFileResult(url: missing, status: .alreadyAbsent)]
        )
        #expect(!onlyMissing.offersOpenTrash)
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

    /// Two copies of one app, removed together: the first copy's group holds its own item and
    /// one the second copy also claims.
    private struct TwoCopies {
        let first: ApplicationInfo
        let second: ApplicationInfo
        let own: LeftoverItem
        let shared: LeftoverItem

        var group: LeftoverGroup { LeftoverGroup(app: first, items: [shared, own]) }
    }

    private func twoCopies() -> TwoCopies {
        let first = app("Twin")
        var second = app("Twin")
        second.path = URL(filePath: "/Users/Shared/Twin.app", directoryHint: .isDirectory)
        return TwoCopies(
            first: first,
            second: second,
            own: LeftoverItem(url: URL(filePath: "/tmp/Twin/Caches", directoryHint: .isDirectory), source: .bundleIdentifier),
            shared: LeftoverItem(
                url: URL(filePath: "/tmp/Twin/Application Support", directoryHint: .isDirectory),
                source: .bundleIdentifier,
                coTargets: [second.id]
            )
        )
    }

    @Test func sharedItemStaysWhenOneCopyFails() async {
        let copies = twoCopies()
        let recorder = Recorder()
        let failingPath = copies.second.path
        let sut = coordinator(
            facts: .userOwnedWritable,
            trash: { url in if url == failingPath { throw TrashRefused() } },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) }
        )

        let outcome = await sut.uninstall(
            targets: [copies.first, copies.second], zap: false, leftovers: [copies.group], using: BrewService()
        )

        #expect(outcome.results[copies.first.id] == .movedToTrash)
        #expect(outcome.results[copies.second.id] == .failed("trash refused"))
        #expect(recorder.trashedLeftovers == [copies.own.url])
        #expect(outcome.leftoversTrashed == 1)
    }

    @Test func sharedItemGoesWhenBothCopiesRemoved() async {
        let copies = twoCopies()
        let recorder = Recorder()
        let sut = coordinator(
            facts: .userOwnedWritable,
            trash: { _ in },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) }
        )

        let outcome = await sut.uninstall(
            targets: [copies.first, copies.second], zap: false, leftovers: [copies.group], using: BrewService()
        )

        #expect(outcome.results[copies.first.id] == .movedToTrash)
        #expect(outcome.results[copies.second.id] == .movedToTrash)
        #expect(recorder.trashedLeftovers == [copies.shared.url, copies.own.url])
    }

    @Test func blockedTargetIsNotAttempted() async {
        let target = app("Root")
        let calls = CallCounter()
        let sut = coordinator(facts: .rootOwnedReadOnly, trash: { _ in calls.increment() })

        let outcome = await sut.uninstall(targets: [target], zap: false, using: BrewService())

        #expect(calls.count == 0)
        #expect(outcome.results[target.id] == .blocked(.needsAdministratorRights))
    }

    @Test func routesPreflightOnlyNonBrewTargets() async {
        let manual = app("Manual"), cask = app("Cask", brew: true)
        let sut = coordinator(facts: .rootOwnedReadOnly, trash: { _ in })

        let routes = await sut.routes(for: [manual, cask])

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
        #expect(recorder.trashedLeftovers == leftovers(for: target).items.map(\.url))
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

    private struct HelperFailureRun {
        let result: UninstallTargetResult?
        let outcome: UninstallCoordinator.Outcome
        let recorder: Recorder
        let original: URL
    }

    private func runHelperFailure(_ failure: Error) async -> HelperFailureRun {
        let target = app("Root")
        let denied = permissionDenied()
        let recorder = Recorder()
        let sut = coordinator(
            facts: .rootOwnedHelperEnabled,
            trash: { url in
                recorder.recordTrash(url)
                throw denied
            },
            trashLeftovers: { recorder.recordLeftovers($0); return LeftoverCleanup.Result(removed: $0) },
            stage: { _, _ in throw failure }
        )
        let outcome = await sut.uninstall(
            targets: [target], zap: false, leftovers: [leftovers(for: target)], using: BrewService()
        )
        return HelperFailureRun(
            result: outcome.results[target.id], outcome: outcome, recorder: recorder, original: target.path
        )
    }

    nonisolated private static let xpcInterrupted = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)

    @Test func helperThatIsOffReadsAsNeedsHelper() async {
        let failure = PrivilegedHelperClient.StagingFailure(
            underlying: PrivilegedHelperClient.HelperError.notEnabled, requestSent: false
        )

        let run = await runHelperFailure(failure)

        #expect(run.result == .blocked(.needsHelper))
        #expect(run.recorder.trashed == [run.original])
        #expect(run.recorder.trashedLeftovers.isEmpty)
    }

    /// A helper older than this app (protocol 5), or one that does not answer the handshake,
    /// was never sent the request: the app is still in /Applications and the helper has to be
    /// removed and installed again.
    @Test(arguments: [
        PrivilegedHelperClient.HelperError.versionMismatch(helper: "5", expected: WegaHelper.version),
        PrivilegedHelperClient.HelperError.timedOut,
        PrivilegedHelperClient.HelperError.connectionFailed,
        xpcInterrupted,
    ] as [any Error])
    func outdatedOrSilentHelperMustBeReinstalled(_ error: any Error) async {
        let failure = PrivilegedHelperClient.StagingFailure(underlying: error, requestSent: false)

        let run = await runHelperFailure(failure)

        #expect(run.result == .blocked(.helperNeedsReinstall))
        #expect(run.recorder.trashed == [run.original])
        #expect(run.recorder.trashedLeftovers.isEmpty)
        #expect(run.outcome.leftoversTrashed == 0)
    }

    @Test func helperErrorIsFailedWithItsMessage() async {
        let failure = PrivilegedHelperClient.StagingFailure(
            underlying: PrivilegedHelperClient.HelperError.operationFailed("Aplikacja nie należy do roota."),
            requestSent: true
        )

        let run = await runHelperFailure(failure)

        #expect(run.result == .failed("Aplikacja nie należy do roota."))
        #expect(run.recorder.trashedLeftovers.isEmpty)
    }

    /// Once the request may have reached the helper, a timeout or a lost connection does not say
    /// the removal failed: the app may already be out of /Applications. Nothing else is touched.
    @Test(arguments: [
        PrivilegedHelperClient.HelperError.timedOut,
        PrivilegedHelperClient.HelperError.connectionFailed,
        xpcInterrupted,
    ] as [any Error])
    func unconfirmedStagingSaysTheAppMayAlreadyHaveLeft(_ error: any Error) async {
        let failure = PrivilegedHelperClient.StagingFailure(underlying: error, requestSent: true)

        let run = await runHelperFailure(failure)

        let message = UninstallCoordinator.unconfirmedHelperRemoval
        #expect(run.result == .failed(message))
        #expect(message.contains("/Applications"))
        #expect(message != error.localizedDescription)
        #expect(run.recorder.trashed == [run.original])
        #expect(run.recorder.trashedLeftovers.isEmpty)
        #expect(run.outcome.leftoversTrashed == 0)
    }

    /// An error that does not say whether the request was sent is reported as if it may have been.
    @Test func aFailureOfUnknownPhaseIsTreatedAsPossiblySent() async {
        let run = await runHelperFailure(PrivilegedHelperClient.HelperError.timedOut)

        #expect(run.result == .failed(UninstallCoordinator.unconfirmedHelperRemoval))
        #expect(run.recorder.trashedLeftovers.isEmpty)
    }

    /// Ruling 19: whether the staging request was sent decides between "reinstall the helper"
    /// (nothing happened) and "may already have left /Applications" (something may have).
    @Test func helperFailureTellsASentRequestFromOneThatWasNot() {
        typealias HelperError = PrivilegedHelperClient.HelperError
        struct Case {
            let error: any Error
            let sent: Bool
            let expected: UninstallTargetResult
        }
        let reinstall = UninstallTargetResult.blocked(.helperNeedsReinstall)
        let unconfirmed = UninstallTargetResult.failed(UninstallCoordinator.unconfirmedHelperRemoval)
        let cases: [Case] = [
            Case(error: HelperError.timedOut, sent: false, expected: reinstall),
            Case(error: HelperError.connectionFailed, sent: false, expected: reinstall),
            Case(error: Self.xpcInterrupted, sent: false, expected: reinstall),
            Case(error: HelperError.versionMismatch(helper: "5", expected: "6"), sent: false, expected: reinstall),
            Case(error: HelperError.timedOut, sent: true, expected: unconfirmed),
            Case(error: HelperError.connectionFailed, sent: true, expected: unconfirmed),
            Case(error: Self.xpcInterrupted, sent: true, expected: unconfirmed),
            Case(error: HelperError.notEnabled, sent: false, expected: .blocked(.needsHelper)),
            Case(error: HelperError.notEnabled, sent: true, expected: .blocked(.needsHelper)),
            Case(error: HelperError.operationFailed("nie"), sent: true, expected: .failed("nie")),
        ]
        for item in cases {
            #expect(
                UninstallCoordinator.helperFailure(item.error, requestSent: item.sent) == item.expected,
                "\(item.error), sent: \(item.sent)"
            )
        }
    }

    @Test func helperRouteIsPreflightedForTheSheet() async {
        let target = app("Root")
        let sut = coordinator(facts: .rootOwnedHelperEnabled, trash: { _ in })

        #expect(await sut.routes(for: [target])[target.id] == .helper)
    }

    private func handshakeCoordinator(
        facts: UninstallBundleFacts,
        handshake: @escaping @Sendable () async -> UninstallHelperAvailability,
        running: [RunningApplicationTarget] = [],
        quits: CallCounter = CallCounter()
    ) -> UninstallCoordinator {
        UninstallCoordinator(dependencies: .init(
            uninstallCask: { _, _, _ in },
            trashItem: { _ in },
            trashLeftovers: { LeftoverCleanup.Result(removed: $0) },
            protection: { _ in nil },
            runningApplications: { running },
            requestQuit: { _ in quits.increment(); return false },
            forceKill: { _ in false },
            waitBetweenRunningChecks: {},
            bundleFacts: { _ in facts },
            stageForTrash: { _, _ in throw StagingNotExpected() },
            helperHandshake: handshake
        ))
    }

    @Test func handshakeRunsOnceForAllHelperTargets() async {
        let calls = CallCounter()
        let sut = handshakeCoordinator(facts: .rootOwnedHelperEnabled, handshake: { calls.increment(); return .enabled })

        let routes = await sut.routes(for: [app("One"), app("Two")])

        #expect(calls.count == 1)
        #expect(routes.values.allSatisfy { $0 == .helper })
    }

    @Test func noHandshakeWhenNoTargetNeedsTheHelper() async {
        let calls = CallCounter()
        for facts in [UninstallBundleFacts.userOwnedWritable, .rootOwnedReadOnly] {
            let sut = handshakeCoordinator(facts: facts, handshake: { calls.increment(); return .stale })
            _ = await sut.routes(for: [app("Plain"), app("Cask", brew: true)])
        }
        #expect(calls.count == 0)
    }

    @Test func staleHelperTargetIsNotAskedToQuit() async throws {
        let target = app("Root")
        let quits = CallCounter()
        let running = [RunningApplicationTarget(
            processIdentifier: 99, bundleURL: target.path, bundleIdentifier: target.bundleIdentifier,
            appName: target.name, processName: target.name
        )]
        let sut = handshakeCoordinator(
            facts: .rootOwnedHelperEnabled,
            handshake: { .stale }, running: running, quits: quits
        )

        let routes = await sut.routes(for: [target])
        let plan = try #require(await sut.runQuitPhase(targets: [target], routes: routes, askForceQuit: { _ in .skip }))

        #expect(routes[target.id] == .blocked(.helperNeedsReinstall))
        #expect(quits.count == 0)
        #expect(plan.remove.isEmpty)
        #expect(plan.skipped[target.id] == .blocked(.helperNeedsReinstall))
    }

    @Test func offRegistrationIsNotOverriddenByTheHandshake() async {
        let target = app("Root")
        var facts = UninstallBundleFacts.rootOwnedHelperEnabled
        facts.helper = .off
        let calls = CallCounter()
        let sut = handshakeCoordinator(facts: facts, handshake: { calls.increment(); return .enabled })

        #expect(await sut.routes(for: [target])[target.id] == .blocked(.needsHelper))
        #expect(calls.count == 0)
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
