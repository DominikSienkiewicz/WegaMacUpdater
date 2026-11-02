import Foundation
import Testing
@testable import MacUpdaterCore

private actor DockerStopRunner: ProcessRunning {
    enum Reply: Sendable {
        case exit(Int32)
        case failure(ProcessRunnerError)
    }

    private var replies: [Reply]
    private(set) var requests: [ProcessRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        guard !replies.isEmpty else { return ProcessResult(exitCode: 3, stdout: "", stderr: "unexpected probe") }
        switch replies.removeFirst() {
        case .exit(let code): return ProcessResult(exitCode: code, stdout: "", stderr: "")
        case .failure(let error): throw error
        }
    }

    nonisolated func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Docker Desktop controlled shutdown")
struct DockerDesktopStopperTests {
    private let bundle = URL(fileURLWithPath: "/Applications/Docker.app")

    @Test func refusedShutdownNeverPermitsBundleReplacement() async {
        let runner = DockerStopRunner([.exit(0), .exit(1)])
        let result = await stopper(runner).stop(bundleURL: bundle)
        #expect(!result.allowsBundleMutation)
        #expect(await runner.requests.count == 2)
    }

    @Test func successfulCommandStillWaitsForBackendExit() async throws {
        let runner = DockerStopRunner([.exit(0), .exit(0), .exit(0), .exit(1)])
        let result = await stopper(runner).stop(bundleURL: bundle)
        #expect(result == .stopped)
        let requests = await runner.requests
        try #require(requests.count == 4)
        #expect(requests.dropFirst(2).allSatisfy { $0.executableURL.path == "/usr/bin/pgrep" })
        #expect(requests[1].executableURL == bundle.appendingPathComponent("Contents/Resources/cli-plugins/docker-desktop"))
        #expect(requests[1].arguments == ["desktop", "stop", "--timeout", "60"])
        #expect(requests.allSatisfy { $0.timeout != nil && $0.idleTimeout != nil })
        #expect(requests.allSatisfy { !$0.arguments.contains("--force") && !$0.arguments.contains("-KILL") })
        #expect(!requests[1].inheritParentEnvironment)
        #expect(requests[1].environment["DOCKER_HOST"] == nil)
        #expect(requests[1].environment["DOCKER_CONTEXT"] == nil)
    }

    @Test func localBackendProbeIncludesRenamedAndSymlinkedDockerBundles() async throws {
        let runner = DockerStopRunner([.exit(1)])
        _ = await stopper(runner).stop(bundleURL: bundle)
        let request = try #require(await runner.requests.first)
        let pattern = try #require(request.arguments.last)
        let expression = try NSRegularExpression(pattern: pattern)
        for command in [
            "/Applications/Docker.old.app/Contents/MacOS/com.docker.backend -watchdog",
            "/opt/homebrew/Caskroom/docker-desktop/old/Docker.app/Contents/MacOS/com.docker.virtualization",
            "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop"
        ] {
            #expect(expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil)
        }
        let unrelated = "/Applications/Other.app/Contents/MacOS/Other --label com.docker.backend"
        #expect(expression.firstMatch(in: unrelated, range: NSRange(unrelated.startIndex..., in: unrelated)) == nil)
    }

    @Test func backendStillAliveAfterBoundedPollingBlocksReplacement() async {
        let runner = DockerStopRunner([.exit(0), .exit(0), .exit(0), .exit(0)])
        let result = await stopper(runner, probes: 2).stop(bundleURL: bundle)
        #expect(result == .timedOut)
        #expect(await runner.requests.count == 4)
    }

    @Test func processProbeErrorIsNotEvidenceOfStoppedDesktop() async {
        let runner = DockerStopRunner([.exit(2)])
        let result = await stopper(runner).stop(bundleURL: bundle)
        #expect(!result.allowsBundleMutation)
        #expect(await runner.requests.count == 1)
    }

    @Test func missingPluginBlocksRunningDesktop() async {
        let runner = DockerStopRunner([.exit(0)])
        let service = DockerDesktopStopper(runner: runner, executableExists: { _ in false }, pause: {})
        #expect(await service.stop(bundleURL: bundle) == .unsupported)
        #expect(await runner.requests.count == 1)
    }

    @Test func alreadyStoppedDesktopNeedsNoShutdownCommand() async {
        let runner = DockerStopRunner([.exit(1)])
        #expect(await stopper(runner).stop(bundleURL: bundle) == .stopped)
        #expect(await runner.requests.count == 1)
    }

    @Test(arguments: [ProcessRunnerError.timedOut(seconds: 60), .idleTimedOut(seconds: 60), .cancelled])
    func timeoutAndCancellationFailClosed(error: ProcessRunnerError) async {
        let runner = DockerStopRunner([.exit(0), .failure(error)])
        let result = await stopper(runner).stop(bundleURL: bundle)
        #expect(result == (error == .cancelled ? .cancelled : .timedOut))
    }

    @Test(arguments: ["docker", "docker-desktop", "homebrew/cask/docker-desktop"])
    func aliasesCannotBypassShutdown(token: String) async {
        let result = await DockerDesktopMutationGate.stopIfNeeded(token: token, bundleURL: bundle) { _ in .timedOut }
        #expect(DockerDesktopMutationGate.isDocker(token: token))
        #expect(result == .timedOut)
    }

    @Test func missingBundlePathBlocksDockerMutation() async {
        let result = await DockerDesktopMutationGate.stopIfNeeded(token: "docker-desktop", bundleURL: nil) { _ in .stopped }
        #expect(result != nil)
        #expect(result?.allowsBundleMutation == false)
    }

    @Test func unrelatedCaskDoesNotStopDocker() async {
        let result = await DockerDesktopMutationGate.stopIfNeeded(token: "figma", bundleURL: bundle) { _ in
            Issue.record("Unrelated cask must not request Docker shutdown")
            return .timedOut
        }
        #expect(result == nil)
        #expect(!DockerDesktopMutationGate.isDocker(token: "docker-compose"))
    }

    private func stopper(_ runner: DockerStopRunner, probes: Int = 3) -> DockerDesktopStopper {
        DockerDesktopStopper(runner: runner, executableExists: { _ in true }, maximumProbes: probes, pause: {})
    }
}
