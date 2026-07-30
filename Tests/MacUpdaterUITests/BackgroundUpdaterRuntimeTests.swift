import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

private enum BackgroundRuntimeError: Error {
    case expected
}

@MainActor
private final class BackgroundRuntimeRecorder {
    let root: URL
    let store: UpdateOperationStore
    var calls: [String: Int] = [:]
    var brewArguments: [[String]] = []
    var brewOutcomes: [BrewUpgradeOutcome]
    var notifications: [UpdateRunSummary] = []
    var runningTokenResults: [Set<String>]

    init(
        brewOutcomes: [BrewUpgradeOutcome] = [
            BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: []),
        ],
        runningTokenResults: [Set<String>] = []
    ) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-runtime-\(UUID().uuidString)", isDirectory: true)
        store = UpdateOperationStore(rootDirectory: root)
        self.brewOutcomes = brewOutcomes
        self.runningTokenResults = runningTokenResults
    }

    static let success = BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])

    func record(_ name: String) {
        calls[name, default: 0] += 1
    }

    func nextRunningTokens() -> Set<String> {
        record("running")
        guard !runningTokenResults.isEmpty else { return [] }
        return runningTokenResults.removeFirst()
    }

    func nextBrewOutcome(arguments: [String]) -> BrewUpgradeOutcome {
        record("brew")
        brewArguments.append(arguments)
        return brewOutcomes.isEmpty ? Self.success : brewOutcomes.removeFirst()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Background updater runtime coverage")
@MainActor
struct BackgroundUpdaterRuntimeTests {
    private static let token = "figma"
    private static let appURL = URL(fileURLWithPath: "/Applications/Figma.app")

    private var validPreflight: BackgroundUpdatePreflight {
        BackgroundUpdatePreflight(
            profiles: [
                CaskArtifactProfile(
                    token: Self.token,
                    artifacts: [CaskArtifact(kind: .app, names: ["Figma.app"])]
                ),
            ],
            downloads: [
                CaskDownloadInfo(
                    token: Self.token,
                    url: "https://example.test/figma.zip",
                    sha256: "abc"
                ),
            ],
            appPaths: [Self.token: Self.appURL]
        )
    }

    private func dependencies(
        recorder: BackgroundRuntimeRecorder,
        optedIn: Set<String> = [Self.token],
        allowsRound: Bool = true,
        preflight: BackgroundUpdatePreflight? = nil,
        preflightThrows: Bool = false,
        performWriteThrows: Bool = false,
        acquireMutex: Bool = true,
        lockedPolicies: [String: UpdatePolicy] = [:],
        resourceDecision: DownloadGate.Decision = .allow,
        publisherVetoes: [String: TeamIDAudit] = [:],
        snapshotSucceeds: Bool = true,
        verification: CaskValidationVerdict = .healthy,
        rescan: BrewOutdated? = BrewOutdated(formulae: [], casks: [])
    ) -> BackgroundUpdater.Dependencies {
        let resolvedPreflight = preflight ?? validPreflight
        return BackgroundUpdater.Dependencies(
            optedInTokens: {
                recorder.record("optedIn")
                return optedIn
            },
            allowsRound: {
                recorder.record("allows")
                return allowsRound
            },
            loadPreflight: { _ in
                recorder.record("preflight")
                if preflightThrows { throw BackgroundRuntimeError.expected }
                return resolvedPreflight
            },
            runningTokens: { _ in recorder.nextRunningTokens() },
            probeDownloadSizes: { tokens, _ in
                Dictionary(uniqueKeysWithValues: tokens.map { ($0, .known(bytes: 1_024)) })
            },
            performWrite: { operation in
                recorder.record("write")
                if performWriteThrows { throw BackgroundRuntimeError.expected }
                return await operation()
            },
            acquireMutex: {
                recorder.record("acquire")
                return acquireMutex
            },
            releaseMutex: { recorder.record("release") },
            policies: {
                recorder.record("policies")
                return lockedPolicies
            },
            resourceDecision: { _, _, _ in
                recorder.record("resources")
                return resourceDecision
            },
            publisherVetoes: { _, _ in
                recorder.record("publisher")
                return publisherVetoes
            },
            beginOperation: {
                recorder.record("begin")
                return recorder.store.begin(trigger: .background)
            },
            snapshot: { tokens, _, operation in
                recorder.record("snapshot")
                guard snapshotSucceeds else { return [:] }
                return Dictionary(uniqueKeysWithValues: tokens.map { token in
                    let name = UpdateOperationSession.snapshotDirectoryName(for: token)
                    operation.recordSnapshotted(token: token, snapshotName: name)
                    return (token, operation.snapshotsDirectory.appendingPathComponent(name))
                })
            },
            removeOperation: {
                recorder.record("remove")
                recorder.store.removeOperation(id: $0)
            },
            runBrew: { recorder.nextBrewOutcome(arguments: $0) },
            recordAppManagementDenial: { recorder.record("denial") },
            clearAppManagementDenial: { recorder.record("clearDenial") },
            verify: { tokens, _, _, operation in
                recorder.record("verify")
                for token in tokens {
                    operation.recordVerdict(token: token, verdict: verification)
                }
                return Dictionary(uniqueKeysWithValues: tokens.map { ($0, verification) })
            },
            outdatedGreedy: {
                guard let rescan else { throw BackgroundRuntimeError.expected }
                return rescan
            },
            notify: {
                recorder.record("notify")
                recorder.notifications.append($0)
            }
        )
    }

    @Test func emptyCandidatesAndEmptyConsentStopBeforePreflight() async {
        let recorder = BackgroundRuntimeRecorder()
        defer { recorder.cleanUp() }
        let updater = BackgroundUpdater(dependencies: dependencies(recorder: recorder))

        #expect(await updater.runIfEligible(candidates: [], policies: [:]).isEmpty)

        let noConsent = BackgroundRuntimeRecorder()
        defer { noConsent.cleanUp() }
        let noConsentUpdater = BackgroundUpdater(dependencies: dependencies(
            recorder: noConsent,
            optedIn: []
        ))
        #expect(await noConsentUpdater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(recorder.calls["preflight"] == nil)
        #expect(noConsent.calls["preflight"] == nil)
    }

    @Test func permissionCooldownAndPreflightFailureStopWithoutMutation() async {
        let denied = BackgroundRuntimeRecorder()
        defer { denied.cleanUp() }
        let deniedUpdater = BackgroundUpdater(dependencies: dependencies(
            recorder: denied,
            allowsRound: false
        ))
        #expect(await deniedUpdater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(denied.calls["preflight"] == nil)

        let broken = BackgroundRuntimeRecorder()
        defer { broken.cleanUp() }
        let brokenUpdater = BackgroundUpdater(dependencies: dependencies(
            recorder: broken,
            preflightThrows: true
        ))
        #expect(await brokenUpdater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(broken.calls["write"] == nil)
    }

    @Test func incompleteMetadataAndInitialPolicyVetoStopBeforeTheWriteQueue() async {
        let incomplete = BackgroundRuntimeRecorder()
        defer { incomplete.cleanUp() }
        let emptyPreflight = BackgroundUpdatePreflight(profiles: [], downloads: [], appPaths: [:])
        let incompleteUpdater = BackgroundUpdater(dependencies: dependencies(
            recorder: incomplete,
            preflight: emptyPreflight
        ))
        #expect(await incompleteUpdater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)

        let policy = BackgroundRuntimeRecorder()
        defer { policy.cleanUp() }
        let policyUpdater = BackgroundUpdater(dependencies: dependencies(recorder: policy))
        #expect(await policyUpdater.runIfEligible(
            candidates: [Self.token],
            policies: ["c:\(Self.token)": .ignored]
        ).isEmpty)
        #expect(incomplete.calls["write"] == nil)
        #expect(policy.calls["write"] == nil)
    }

    @Test func writeQueueMutexAndLockedStateFailuresReleaseOnlyWhenAcquired() async {
        let writeFailure = BackgroundRuntimeRecorder()
        defer { writeFailure.cleanUp() }
        let writeFailureUpdater = BackgroundUpdater(dependencies: dependencies(
            recorder: writeFailure,
            performWriteThrows: true
        ))
        #expect(await writeFailureUpdater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(writeFailure.calls["acquire"] == nil)

        let mutex = BackgroundRuntimeRecorder()
        defer { mutex.cleanUp() }
        let mutexUpdater = BackgroundUpdater(dependencies: dependencies(
            recorder: mutex,
            acquireMutex: false
        ))
        #expect(await mutexUpdater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(mutex.calls["release"] == nil)

        let locked = BackgroundRuntimeRecorder(runningTokenResults: [[], [Self.token]])
        defer { locked.cleanUp() }
        let lockedUpdater = BackgroundUpdater(dependencies: dependencies(recorder: locked))
        #expect(await lockedUpdater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(locked.calls["release"] == 1)
        #expect(locked.calls["begin"] == nil)
    }

    @Test func resourcePostponeStopsBeforeJournalingAndReleasesMutex() async {
        let recorder = BackgroundRuntimeRecorder()
        defer { recorder.cleanUp() }
        let updater = BackgroundUpdater(dependencies: dependencies(
            recorder: recorder,
            resourceDecision: .postpone(reason: "metered")
        ))

        #expect(await updater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(recorder.calls["resources"] == 1)
        #expect(recorder.calls["begin"] == nil)
        #expect(recorder.calls["release"] == 1)
    }

    @Test func publisherVetoProducesAUserVisibleOutcomeWithoutRunningBrew() async {
        let recorder = BackgroundRuntimeRecorder()
        defer { recorder.cleanUp() }
        let updater = BackgroundUpdater(dependencies: dependencies(
            recorder: recorder,
            publisherVetoes: [Self.token: .changed(old: "OLD", new: "NEW")]
        ))

        #expect(await updater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(recorder.calls["brew"] == nil)
        #expect(recorder.calls["remove"] == 1)
        #expect(recorder.notifications.first?.publisherChanges.map(\.name) == [Self.token])
    }

    @Test func failedSnapshotAbortsAndRemovesAnEmptyOperation() async {
        let recorder = BackgroundRuntimeRecorder()
        defer { recorder.cleanUp() }
        let updater = BackgroundUpdater(dependencies: dependencies(
            recorder: recorder,
            snapshotSucceeds: false
        ))

        #expect(await updater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(recorder.calls["brew"] == nil)
        #expect(recorder.calls["remove"] == 1)
        #expect(recorder.notifications.isEmpty)
    }

    @Test func successfulRoundRunsEveryPhaseAndReturnsTheUpgradedToken() async {
        let recorder = BackgroundRuntimeRecorder()
        defer { recorder.cleanUp() }
        let updater = BackgroundUpdater(dependencies: dependencies(recorder: recorder))

        let upgraded = await updater.runIfEligible(candidates: [Self.token], policies: [:])

        #expect(upgraded == [Self.token])
        #expect(recorder.calls["brew"] == 1)
        #expect(recorder.calls["clearDenial"] == 1)
        #expect(recorder.calls["verify"] == 1)
        #expect(recorder.calls["notify"] == 1)
        #expect(recorder.calls["release"] == 1)
        #expect(recorder.notifications.first?.allItemsUpgraded == true)
    }

    @Test func strandedUpgradeRetriesOnceWithForceAndCanRecover() async {
        let stranded = BrewUpgradeOutcome(
            exitCode: 1,
            failedTokens: [Self.token],
            errorLines: ["Error: \(Self.token): It seems there is already an App at '/tmp/Figma.app'."]
        )
        let recorder = BackgroundRuntimeRecorder(brewOutcomes: [stranded, .init(
            exitCode: 0,
            failedTokens: [],
            errorLines: []
        )])
        defer { recorder.cleanUp() }
        let updater = BackgroundUpdater(dependencies: dependencies(recorder: recorder))

        #expect(await updater.runIfEligible(candidates: [Self.token], policies: [:]) == [Self.token])
        #expect(recorder.brewArguments.count == 2)
        #expect(recorder.brewArguments[1].contains("--force"))
    }

    @Test func permissionDenialAndFailedRescanProduceAnUnverifiedFailure() async {
        let denial = BrewUpgradeOutcome(
            exitCode: 0,
            failedTokens: [],
            errorLines: [],
            requiresAppManagementPermission: true
        )
        let recorder = BackgroundRuntimeRecorder(brewOutcomes: [denial])
        defer { recorder.cleanUp() }
        let updater = BackgroundUpdater(dependencies: dependencies(
            recorder: recorder,
            rescan: nil
        ))

        #expect(await updater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(recorder.calls["denial"] == 1)
        #expect(recorder.calls["clearDenial"] == nil)
        #expect(recorder.notifications.first?.needsAppManagementPermission == true)
        #expect(recorder.notifications.first?.items.first?.verdict == .notVerified)
    }

    @Test func rescanCanDisproveAnOtherwiseSuccessfulUpgrade() async {
        let stillOutdated = BrewOutdated(
            formulae: [],
            casks: [BrewOutdatedItem(
                name: Self.token,
                installedVersions: ["1.0"],
                currentVersion: "2.0"
            )]
        )
        let recorder = BackgroundRuntimeRecorder()
        defer { recorder.cleanUp() }
        let updater = BackgroundUpdater(dependencies: dependencies(
            recorder: recorder,
            rescan: stillOutdated
        ))

        #expect(await updater.runIfEligible(candidates: [Self.token], policies: [:]).isEmpty)
        #expect(recorder.notifications.first?.items.first?.verdict == .stillOutdated)
    }

    @Test func notificationBodyIncludesEveryActionableOutcomeClause() {
        let summary = UpdateRunSummary(
            items: [
                ItemUpdateOutcome(key: "c:ok", name: "ok", kind: .cask, verdict: .succeeded),
                ItemUpdateOutcome(key: "c:rollback", name: "rollback", kind: .cask, verdict: .rolledBack),
                ItemUpdateOutcome(key: "c:broken", name: "broken", kind: .cask, verdict: .rollbackFailed),
                ItemUpdateOutcome(
                    key: "c:publisher",
                    name: "publisher",
                    kind: .cask,
                    verdict: .publisherChanged(old: "OLD", new: "NEW")
                ),
                ItemUpdateOutcome(key: "c:failed", name: "failed", kind: .cask, verdict: .executionFailed),
            ],
            diagnostics: [],
            needsSudoPassword: false,
            needsAppManagementPermission: true
        )

        let body = BackgroundUpdater.notificationBody(for: summary)

        #expect(body.contains("Zaktualizowano 2"))
        #expect(body.contains("1 cofnięto"))
        #expect(body.contains("broken"))
        #expect(body.contains("publisher"))
        #expect(body.contains("1 nie udało się"))
        #expect(body.contains("Zarządzanie aplikacjami"))
    }
}
