import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Docker first-run authorization smoke exemption")
struct DockerSmokeExemptionTests {
    @Test(arguments: [
        "docker", "docker-desktop", "homebrew/cask/docker", "homebrew/cask/docker-desktop",
        "vendor/tap/docker-desktop", "  HOMEBREW/CASK/DOCKER-DESKTOP\n",
    ])
    func everyDockerCaskNameSkipsAutomaticLaunch(token: String) {
        #expect(LaunchSmokeTestConfiguration.isExemptFromSmokeTest(token: token),
                "Docker aliases and tap-qualified tokens must preserve first-run authorization")
    }

    @Test(arguments: ["obsidian", "docker-compose", "docker-machine", "docker-desktop-beta", "homebrew/cask/docker-compose"])
    func unrelatedCasksKeepTheirSmokeTest(token: String) {
        #expect(!LaunchSmokeTestConfiguration.isExemptFromSmokeTest(token: token))
    }

    @Test func renamedDockerBundleIsRejectedBeforeAnyLaunchAttempt() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try directory.makeApp(
            named: "Renamed Desktop", bundleIdentifier: "com.docker.docker", version: "1.0"
        )

        let outcome = await WorkspaceAppLaunchProbe().launch(bundleAt: bundle)

        guard case .skipped(let reason) = outcome else {
            Issue.record("A Docker bundle must be skipped without launching, regardless of its filename")
            return
        }
        #expect(reason == .privilegedFirstRun,
                "The identity exemption must run before executable validation or NSWorkspace access")
        #expect(!LaunchSmokeTest.requiresRollback(.skipped(reason)))
    }

    @Test func unrelatedBundleNamedDockerRetainsNormalValidation() async throws {
        let directory = try TemporaryDirectory()
        let bundle = try directory.makeApp(
            named: "Docker", bundleIdentifier: "com.example.other", version: "1.0"
        )

        let outcome = await WorkspaceAppLaunchProbe().launch(bundleAt: bundle)

        guard case .skipped(let reason) = outcome else {
            Issue.record("The fixture has no executable and must never be launched")
            return
        }
        #expect(reason == .unsupportedBundle,
                "A filename alone must not exempt unrelated applications")
    }
}
