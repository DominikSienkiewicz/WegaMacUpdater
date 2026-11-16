import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

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
            protection: { _ in nil }
        ))

        let outcome = await coordinator.uninstall(
            targets: [a, b], zap: false, leftovers: [aLeftovers, bLeftovers], using: BrewService()
        )

        #expect(outcome.results[a.id] == .failed("trash refused"))
        #expect(outcome.results[b.id] == .movedToTrash)
        #expect(recorder.trashedLeftovers == bLeftovers.items)
        #expect(outcome.leftoversTrashed == bLeftovers.items.count)
    }

    @Test func brewTargetReportsRemovedByHomebrew() async {
        let cask = app("Charlie", brew: true)
        let coordinator = UninstallCoordinator(dependencies: .init(
            uninstallCask: { _, _, _ in },
            trashItem: { _ in },
            trashLeftovers: { LeftoverCleanup.Result(removed: $0) },
            protection: { _ in nil }
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
            protection: { _ in .systemApplication }
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
