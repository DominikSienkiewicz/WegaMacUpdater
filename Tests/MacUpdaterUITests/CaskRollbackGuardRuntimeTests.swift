import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

private enum GuardRuntimeError: Error {
    case expected
}

private final class GuardRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var appliedStorage: [(String, CaskValidationVerdict)] = []
    private var clonedStorage: [(URL, URL)] = []
    private var removedStorage: [URL] = []
    private var helperReplacementsStorage: [(String, String)] = []

    var applied: [(String, CaskValidationVerdict)] { lock.withLock { appliedStorage } }
    var cloned: [(URL, URL)] { lock.withLock { clonedStorage } }
    var removed: [URL] { lock.withLock { removedStorage } }
    var helperReplacements: [(String, String)] { lock.withLock { helperReplacementsStorage } }

    func recordApplied(_ token: String, _ verdict: CaskValidationVerdict) {
        lock.withLock { appliedStorage.append((token, verdict)) }
    }

    func recordClone(_ source: URL, _ destination: URL) {
        lock.withLock { clonedStorage.append((source, destination)) }
    }

    func recordRemoval(_ url: URL) {
        lock.withLock { removedStorage.append(url) }
    }

    func recordHelperReplacement(_ appPath: String, _ snapshotPath: String) {
        lock.withLock { helperReplacementsStorage.append((appPath, snapshotPath)) }
    }
}

@Suite("Cask rollback guard runtime coverage")
@MainActor
struct CaskRollbackGuardRuntimeTests {
    private func dependencies(
        recorder: GuardRuntimeRecorder = GuardRuntimeRecorder(),
        teamIDBeforeMutation: @escaping @Sendable (URL) -> String? = { _ in "TEAM" },
        teamIDAfterMutation: @escaping @Sendable (URL) async -> String? = { _ in "TEAM" },
        recordTeamID: @escaping @Sendable (String, String?) -> TeamIDAudit = { _, teamID in
            .unchanged(teamID: teamID)
        },
        clone: (@Sendable (URL, URL) throws -> Void)? = nil,
        bundleIdentifier: @escaping @Sendable (URL) -> String? = { _ in "com.example.app" },
        passesGatekeeper: @escaping @Sendable (URL) async -> Bool = { _ in true },
        restore: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in },
        helperIsEnabled: @escaping @MainActor @Sendable () -> Bool = { false },
        helperReplace: (@MainActor @Sendable (String, String) async throws -> Void)? = nil,
        smokeTestIsEnabled: @escaping @Sendable () -> Bool = { false },
        launchSmokeTest: @escaping @Sendable (URL) async -> LaunchSmokeTest.Verdict = { _ in
            .survived
        }
    ) -> CaskRollbackGuard.Dependencies {
        CaskRollbackGuard.Dependencies(
            teamIDBeforeMutation: teamIDBeforeMutation,
            teamIDAfterMutation: teamIDAfterMutation,
            recordTeamID: recordTeamID,
            applyRollbackLedger: { recorder.recordApplied($0, $1) },
            clone: clone ?? { recorder.recordClone($0, $1) },
            bundleIdentifier: bundleIdentifier,
            passesGatekeeper: passesGatekeeper,
            restore: restore,
            helperIsEnabled: helperIsEnabled,
            helperReplace: helperReplace ?? {
                recorder.recordHelperReplacement($0, $1)
            },
            removeItem: { recorder.recordRemoval($0) },
            smokeTestIsEnabled: smokeTestIsEnabled,
            launchSmokeTest: launchSmokeTest
        )
    }

    private func session(tokens: [String]) -> (UpdateOperationStore, UpdateOperationSession) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-runtime-\(UUID().uuidString)", isDirectory: true)
        let store = UpdateOperationStore(rootDirectory: root)
        let session = store.begin(trigger: .manual)
        let paths = Dictionary(uniqueKeysWithValues: tokens.map {
            ($0, URL(fileURLWithPath: "/Applications/\($0).app"))
        })
        session.recordPlanned(tokens: tokens, appPaths: paths)
        return (store, session)
    }

    @Test func publisherVetoesOnlyChangedPublishersWithResolvedPaths() {
        let stable = URL(fileURLWithPath: "/Applications/Stable.app")
        let changed = URL(fileURLWithPath: "/Applications/Changed.app")
        let dependencies = dependencies(
            teamIDBeforeMutation: { $0 == changed ? "NEW" : "SAME" },
            recordTeamID: { key, teamID in
                key.contains("changed")
                    ? .changed(old: "OLD", new: teamID)
                    : .unchanged(teamID: teamID)
            }
        )

        let vetoes = CaskRollbackGuard.publisherVetoes(
            tokens: ["missing", "stable", "changed"],
            appPaths: ["stable": stable, "changed": changed],
            dependencies: dependencies
        )

        #expect(vetoes.keys.sorted() == ["changed"])
    }

    @Test func snapshotRecordsOnlySuccessfulClones() {
        let (store, operation) = session(tokens: ["good", "bad"])
        defer { try? FileManager.default.removeItem(at: store.operationDirectory(id: operation.operation.id)) }
        let dependencies = dependencies(clone: { source, _ in
            if source.path.contains("bad") { throw GuardRuntimeError.expected }
        })

        let snapshots = CaskRollbackGuard.snapshot(
            tokens: ["missing", "good", "bad"],
            appPaths: [
                "good": URL(fileURLWithPath: "/Applications/good.app"),
                "bad": URL(fileURLWithPath: "/Applications/bad.app"),
            ],
            operation: operation,
            dependencies: dependencies
        )

        #expect(snapshots.keys.sorted() == ["good"])
        #expect(operation.operation.items.first { $0.token == "good" }?.phase == .snapshotted)
        #expect(operation.operation.items.first { $0.token == "bad" }?.phase == .planned)
    }

    @Test func batchVerificationCommitsAHealthyItemAndSkipsMissingPaths() async {
        let recorder = GuardRuntimeRecorder()
        let (store, operation) = session(tokens: ["healthy"])
        defer { try? FileManager.default.removeItem(at: store.operationDirectory(id: operation.operation.id)) }
        operation.recordSnapshotted(token: "healthy", snapshotName: "healthy.app")
        operation.recordInstalling()

        let outcomes = await CaskRollbackGuard.verify(
            tokens: ["missing", "healthy"],
            appPaths: ["healthy": URL(fileURLWithPath: "/Applications/healthy.app")],
            snapshots: [:],
            operation: operation,
            dependencies: dependencies(recorder: recorder)
        )

        #expect(outcomes == ["healthy": .healthy])
        #expect(operation.operation.items.first?.phase == .committed)
        #expect(recorder.applied.map(\.0) == ["healthy"])
    }

    @Test func bundleIdentityMismatchPreservesSnapshotAndRollsBack() async {
        let recorder = GuardRuntimeRecorder()
        let snapshot = URL(fileURLWithPath: "/tmp/original.app")
        let installed = URL(fileURLWithPath: "/Applications/new.app")

        let verdict = await CaskRollbackGuard.verify(
            token: "identity",
            snapshotURL: snapshot,
            validationURL: installed,
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.expected", version: nil),
            dependencies: dependencies(
                recorder: recorder,
                bundleIdentifier: { _ in "com.other" }
            )
        )

        #expect(verdict == .rolledBack)
        #expect(recorder.cloned.first?.0 == snapshot)
        #expect(recorder.removed.count == 1)
    }

    @Test func publisherChangeUsesHelperFallbackAndKeepsOriginalSnapshot() async {
        let recorder = GuardRuntimeRecorder()
        let verdict = await CaskRollbackGuard.verify(
            token: "publisher",
            snapshotURL: URL(fileURLWithPath: "/tmp/publisher.app"),
            validationURL: URL(fileURLWithPath: "/Applications/publisher.app"),
            expecting: .init(teamID: "OLD", bundleIdentifier: "com.example.app", version: nil),
            dependencies: dependencies(
                recorder: recorder,
                teamIDAfterMutation: { _ in "NEW" },
                restore: { _, _ in throw GuardRuntimeError.expected },
                helperIsEnabled: { true }
            )
        )

        #expect(verdict == .publisherChangedAndRolledBack(old: "OLD", new: "NEW"))
        #expect(recorder.helperReplacements.count == 1)
        #expect(recorder.removed.count == 1)
    }

    @Test func rejectedGatekeeperWithoutSnapshotIsUnrecoverable() async {
        let (_, operation) = session(tokens: ["unsafe"])
        let outcomes = await CaskRollbackGuard.verify(
            tokens: ["unsafe"],
            appPaths: ["unsafe": URL(fileURLWithPath: "/Applications/unsafe.app")],
            snapshots: [:],
            operation: operation,
            dependencies: dependencies(passesGatekeeper: { _ in false })
        )

        #expect(outcomes == ["unsafe": .rollbackFailed])
    }

    @Test(arguments: [
        LaunchSmokeTest.Verdict.survived,
        .skipped(.alreadyRunning),
        .exitedEarly(after: 0.1),
        .launchFailed("boom"),
    ])
    func smokeTestVerdictsKeepOrRestoreTheBundle(verdict: LaunchSmokeTest.Verdict) async {
        let recorder = GuardRuntimeRecorder()
        let outcome = await CaskRollbackGuard.verify(
            token: "smoke",
            snapshotURL: URL(fileURLWithPath: "/tmp/smoke.app"),
            validationURL: URL(fileURLWithPath: "/Applications/smoke.app"),
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.example.app", version: nil),
            dependencies: dependencies(
                recorder: recorder,
                smokeTestIsEnabled: { true },
                launchSmokeTest: { _ in verdict }
            )
        )

        if LaunchSmokeTest.requiresRollback(verdict) {
            #expect(outcome == .rolledBack)
        } else {
            #expect(outcome == .healthy)
        }
    }

    @Test func restoreFailureIsReportedWhenTheHelperIsUnavailableOrFails() async {
        let restoreFails = dependencies(restore: { _, _ in throw GuardRuntimeError.expected })
        let unavailable = await CaskRollbackGuard.restoreSnapshot(
            URL(fileURLWithPath: "/tmp/a.app"),
            to: URL(fileURLWithPath: "/Applications/a.app"),
            dependencies: restoreFails
        )
        #expect(!unavailable)

        let helperFails = dependencies(
            restore: { _, _ in throw GuardRuntimeError.expected },
            helperIsEnabled: { true },
            helperReplace: { _, _ in throw GuardRuntimeError.expected }
        )
        let failed = await CaskRollbackGuard.restoreSnapshot(
            URL(fileURLWithPath: "/tmp/b.app"),
            to: URL(fileURLWithPath: "/Applications/b.app"),
            dependencies: helperFails
        )
        #expect(!failed)
    }

    /// Discord, 2026-10-27: every gate approved the brew-installed `0.0.420`, then the app's own
    /// updater (Squirrel's ShipIt) put `0.0.419` back as the launch test closed it — and the
    /// update was reported as applied while Homebrew kept recording `0.0.420`.
    @Test func aBundleTheAppReplacedDuringTheLaunchTestIsNotReportedAsUpdated() async throws {
        // Given the cask landed 0.0.420 over a 0.0.419 snapshot
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-app-updater-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try Self.bundle(at: root.appendingPathComponent("snapshot.app"), version: "0.0.419")
        let installed = try Self.bundle(at: root.appendingPathComponent("Discord.app"), version: "0.0.420")

        // When the app's own updater swaps it back while the launch test has it open
        let outcome = await CaskRollbackGuard.verify(
            token: "discord",
            snapshotURL: snapshot,
            validationURL: installed,
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.example.app", version: "0.0.420"),
            dependencies: dependencies(
                smokeTestIsEnabled: { true },
                launchSmokeTest: { appURL in
                    _ = try? Self.bundle(at: appURL, version: "0.0.419")
                    return .survived
                }
            )
        )

        // Then the verdict says who replaced it and with what, instead of `.healthy`
        #expect(outcome == .replacedByAppUpdater(version: "0.0.419"))
    }

    @Test func aBundleLeftAloneDuringTheLaunchTestStaysHealthy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-app-updater-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try Self.bundle(at: root.appendingPathComponent("snapshot.app"), version: "0.0.419")
        let installed = try Self.bundle(at: root.appendingPathComponent("Discord.app"), version: "0.0.420")

        let outcome = await CaskRollbackGuard.verify(
            token: "discord",
            snapshotURL: snapshot,
            validationURL: installed,
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.example.app", version: "0.0.420"),
            dependencies: dependencies(smokeTestIsEnabled: { true }, launchSmokeTest: { _ in .survived })
        )

        #expect(outcome == .healthy)
    }

    /// The counterweight: an updater that moves the app *past* what brew installed has not undone
    /// anything — the bundle is newer than the update promised, which is no reason to report it
    /// as still outdated.
    @Test func anAppThatUpdatedItselfPastTheCaskDuringTheLaunchTestStaysHealthy() async throws {
        // Given the cask landed 0.0.420 over a 0.0.419 snapshot
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-app-updater-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try Self.bundle(at: root.appendingPathComponent("snapshot.app"), version: "0.0.419")
        let installed = try Self.bundle(at: root.appendingPathComponent("Discord.app"), version: "0.0.420")

        // When the app's own updater moves it on to 0.0.421 while the launch test has it open
        let outcome = await CaskRollbackGuard.verify(
            token: "discord",
            snapshotURL: snapshot,
            validationURL: installed,
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.example.app", version: "0.0.420"),
            dependencies: dependencies(
                smokeTestIsEnabled: { true },
                launchSmokeTest: { appURL in
                    _ = try? Self.bundle(at: appURL, version: "0.0.421")
                    return .survived
                }
            )
        )

        // Then the update stands
        #expect(outcome == .healthy)
    }

    @discardableResult
    private nonisolated static func bundle(at url: URL, version: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version, "CFBundleIdentifier": "com.example.app"],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
