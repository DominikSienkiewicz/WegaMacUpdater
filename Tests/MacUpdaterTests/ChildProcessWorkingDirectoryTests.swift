import Foundation
import Testing
@testable import MacUpdaterCore

/// A child process used to inherit Wega's own working directory. Started from a folder that
/// was later deleted — a removed git worktree, in practice — every `brew` call failed with
/// "$PWD must be set to run brew" and every `npm` call with `uv_cwd ENOENT`, so one scan
/// logged a wall of "Nie udało się sprawdzić" errors for every source. Children now start in
/// `/`, which is what a launch from Finder or the Dock gives the app anyway.
@Suite("Child process working directory")
struct ChildProcessWorkingDirectoryTests {
    @Test func everyChildStartsInTheRootDirectory() async throws {
        let result = try await ProcessRunner().run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/pwd"),
            arguments: ["-P"],
            environment: [:],
            inheritParentEnvironment: true,
            timeouts: .quick
        ))

        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/",
                "the child must not inherit whatever directory the app happened to start in")
    }

    /// The app's own launches outside `ProcessRunner` — the Touch ID setup script and the
    /// relaunch after a self-update — start there too.
    @Test func theAppsOwnLaunchesStartThereToo() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in [
            "Sources/MacUpdater/TouchIDSetupController.swift",
            "Sources/MacUpdater/SelfUpdateController.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("currentDirectoryURL = ProcessRunner.childWorkingDirectory"), "\(path)")
        }
    }
}
