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
}

private struct TrashRefused: LocalizedError {
    var errorDescription: String? { "trash refused" }
}

/// Records what the coordinator hands to the injected seams.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var leftovers: [URL] = []

    func recordLeftovers(_ items: [URL]) {
        lock.lock(); defer { lock.unlock() }
        leftovers.append(contentsOf: items)
    }

    var trashedLeftovers: [URL] {
        lock.lock(); defer { lock.unlock() }
        return leftovers
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
            bundleFacts: { _ in .userOwnedWritable }
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
        trashLeftovers: @escaping @Sendable ([URL]) -> LeftoverCleanup.Result = { LeftoverCleanup.Result(removed: $0) }
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
            bundleFacts: { _ in facts }
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
            hasBundleIdentifier: true
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
            bundleFacts: { _ in .userOwnedWritable }
        ))

        let outcome = await coordinator.uninstall(
            targets: [cask], zap: true, leftovers: [], using: BrewService()
        )

        #expect(outcome.results[cask.id] == .removedByHomebrew)
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
            bundleFacts: { _ in .userOwnedWritable }
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
