import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Docker smoke exemption precedes settings and injected probes")
@MainActor
struct DockerSmokeGuardTests {
    @Test(arguments: ["docker", "docker-desktop", "homebrew/cask/docker", "homebrew/cask/docker-desktop"], [true, false])
    func dockerCannotBeOptedIntoAutomaticLaunch(token: String, enabled: Bool) async {
        let recorder = DockerSmokeGuardRecorder()

        let verdict = await verify(token: token, enabled: enabled, recorder: recorder)

        #expect(verdict == .healthy)
        #expect(recorder.enablementReads == 0,
                "The Docker exemption must precede the user setting, whether enabled or disabled")
        #expect(recorder.launches == 0,
                "An injected launch probe must not bypass Docker's first-run authorization exemption")
        #expect(recorder.restorations == 0)
    }

    @Test func anUnrelatedCaskStillRunsTheEnabledProbe() async {
        let recorder = DockerSmokeGuardRecorder()

        let verdict = await verify(token: "obsidian", enabled: true, recorder: recorder)

        #expect(verdict == .rolledBack)
        #expect(recorder.enablementReads == 1)
        #expect(recorder.launches == 1)
        #expect(recorder.restorations == 1)
    }

    private func verify(
        token: String,
        enabled: Bool,
        recorder: DockerSmokeGuardRecorder
    ) async -> CaskValidationVerdict {
        await CaskRollbackGuard.verify(
            token: token,
            snapshotURL: URL(fileURLWithPath: "/tmp/docker-smoke-test-snapshot.app"),
            validationURL: URL(fileURLWithPath: "/tmp/docker-smoke-test-installed.app"),
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.example.app", version: nil),
            dependencies: .init(
                teamIDBeforeMutation: { _ in "TEAM" },
                teamIDAfterMutation: { _ in "TEAM" },
                recordTeamID: { _, teamID in .unchanged(teamID: teamID) },
                applyRollbackLedger: { _, _ in },
                clone: { _, _ in },
                bundleIdentifier: { _ in "com.example.app" },
                passesGatekeeper: { _ in true },
                restore: { _, _ in recorder.recordRestoration() },
                helperIsEnabled: { false },
                helperReplace: { _, _ in },
                removeItem: { _ in },
                smokeTestIsEnabled: {
                    recorder.recordEnablementRead()
                    return enabled
                },
                launchSmokeTest: { _ in
                    recorder.recordLaunch()
                    return .launchFailed("The fake probe would interrupt Docker authorization")
                }
            )
        )
    }
}

private final class DockerSmokeGuardRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var enablementReadsStorage = 0
    private var launchesStorage = 0
    private var restorationsStorage = 0

    var enablementReads: Int { lock.withLock { enablementReadsStorage } }
    var launches: Int { lock.withLock { launchesStorage } }
    var restorations: Int { lock.withLock { restorationsStorage } }

    func recordEnablementRead() { lock.withLock { enablementReadsStorage += 1 } }
    func recordLaunch() { lock.withLock { launchesStorage += 1 } }
    func recordRestoration() { lock.withLock { restorationsStorage += 1 } }
}
