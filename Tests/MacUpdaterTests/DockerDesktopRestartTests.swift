import Foundation
import Testing
@testable import MacUpdaterCore

struct DockerDesktopRestartTests {
    private let bundleURL = URL(fileURLWithPath: "/TestApplications/Docker.app")
    private let homeURL = URL(fileURLWithPath: "/TestUsers/docker-restart")

    @Test func readyRequiresSuccessfulStopStartAndLocalEngineResponse() async {
        let fixture = RestartFixture(stop: .stopped, responses: [
            .success(.init(exitCode: 0, stdout: "started", stderr: "")),
            .success(.init(exitCode: 0, stdout: "29.0.0\n", stderr: "")),
        ])
        let result = await restarter(fixture).restart(bundleURL: bundleURL)
        #expect(result == .ready)
        #expect(fixture.actions == ["stop", "start", "probe"])
        #expect(fixture.stoppedBundles == [bundleURL])
        let requests = fixture.requests
        #expect(requests.first?.arguments == ["desktop", "start", "--detach"])
        #expect(requests.last?.arguments == [
            "--host", "unix:///TestUsers/docker-restart/.docker/run/docker.sock",
            "info", "--format", "{{.ServerVersion}}",
        ])
        #expect(requests.allSatisfy { $0.executableURL == bundleURL.appendingPathComponent("Contents/Resources/bin/docker") })
        #expect(requests.allSatisfy { !$0.inheritParentEnvironment })
        #expect(requests.allSatisfy { $0.environment["DOCKER_HOST"] == nil && $0.environment["DOCKER_CONTEXT"] == nil })
        #expect(requests.allSatisfy { $0.environment["HOME"] == homeURL.path && ($0.timeout ?? 0) > 0 })
    }

    @Test func unsuccessfulStopNeverStartsOrProbesDocker() async {
        for stop in [DockerDesktopStopResult.unsupported, .failed("stop refused"), .timedOut, .cancelled] {
            let fixture = RestartFixture(stop: stop)
            let result = await restarter(fixture).restart(bundleURL: bundleURL)
            #expect(!result.engineReady)
            #expect(fixture.actions == ["stop"])
            if stop == .cancelled { #expect(result == .cancelled) }
        }
    }

    @Test func failedStartSurfacesItsDiagnosticWithoutProbing() async {
        let fixture = RestartFixture(stop: .stopped, responses: [
            .success(.init(exitCode: 1, stdout: "", stderr: "Desktop start refused")),
        ])
        let result = await restarter(fixture).restart(bundleURL: bundleURL)
        #expect(result == .startFailed("Desktop start refused"))
        #expect(fixture.actions == ["stop", "start"])
    }

    @Test func startupWaitRetriesUntilTheLocalEngineAnswers() async {
        let fixture = RestartFixture(stop: .stopped, responses: [
            .success(.init(exitCode: 0, stdout: "", stderr: "")),
            .success(.init(exitCode: 1, stdout: "", stderr: "socket unavailable")),
            .success(.init(exitCode: 0, stdout: "29.0.0", stderr: "")),
        ])
        let result = await restarter(fixture).restart(bundleURL: bundleURL)
        #expect(result == .ready)
        #expect(fixture.actions == ["stop", "start", "probe", "wait", "probe"])
    }

    @Test func successfulStartWithoutEngineReadinessTimesOutWithLastDiagnostic() async {
        let fixture = RestartFixture(stop: .stopped, responses: [
            .success(.init(exitCode: 0, stdout: "started", stderr: "")),
        ], fallback: .init(exitCode: 1, stdout: "", stderr: "engine not responding"))
        let result = await restarter(fixture).restart(bundleURL: bundleURL)
        #expect(result == .readinessTimedOut("engine not responding"))
        #expect(fixture.requests.count == 4)
        #expect(fixture.elapsed == 5)
        #expect(fixture.requests.dropFirst().allSatisfy { ($0.timeout ?? 6) <= 5 })
    }

    @Test func emptyEngineVersionDoesNotConfirmReadiness() async {
        let fixture = RestartFixture(stop: .stopped, fallback: .init(exitCode: 0, stdout: " \n", stderr: ""))
        let result = await restarter(fixture).restart(bundleURL: bundleURL)
        #expect(!result.engineReady)
        if case .readinessTimedOut = result {} else { Issue.record("Missing server version must remain unconfirmed") }
    }

    @Test func cancellationDuringStartIsReportedWithoutReadiness() async {
        let fixture = RestartFixture(stop: .stopped, responses: [.failure(ProcessRunnerError.cancelled)])
        let result = await restarter(fixture).restart(bundleURL: bundleURL)
        #expect(result == .cancelled)
        #expect(fixture.actions == ["stop", "start"])
    }

    @Test func cancellationDuringWaitStopsPolling() async {
        let fixture = RestartFixture(stop: .stopped, cancelWait: true, responses: [
            .success(.init(exitCode: 0, stdout: "started", stderr: "")),
        ])
        let result = await restarter(fixture).restart(bundleURL: bundleURL)
        #expect(result == .cancelled)
        #expect(fixture.actions == ["stop", "start", "probe", "wait"])
    }

    @Test func unavailableBundledCLIDoesNotStopDocker() async {
        let fixture = RestartFixture(stop: .stopped)
        let result = await restarter(fixture, executableExists: false).restart(bundleURL: bundleURL)
        #expect(!result.engineReady)
        #expect(fixture.actions.isEmpty)
        if case .unknown = result {} else { Issue.record("Missing CLI must be reported as unknown") }
    }

    private func restarter(_ fixture: RestartFixture, executableExists: Bool = true) -> DockerDesktopRestarter {
        DockerDesktopRestarter(
            runner: fixture, stopper: fixture, homeURL: homeURL, readinessTimeout: 5, pollInterval: 2,
            now: { fixture.elapsed }, sleep: { try fixture.wait($0) }, executableExists: { _ in executableExists }
        )
    }
}

private final class RestartFixture: ProcessRunning, DockerDesktopStopping, @unchecked Sendable {
    private let lock = NSLock()
    private let stopResult: DockerDesktopStopResult
    private let cancelWait: Bool
    private var responses: [Result<ProcessResult, Error>]
    private let fallback: ProcessResult
    private var recordedActions: [String] = []
    private var recordedRequests: [ProcessRequest] = []
    private var bundles: [URL] = []
    private var time: TimeInterval = 0

    init(
        stop: DockerDesktopStopResult,
        cancelWait: Bool = false,
        responses: [Result<ProcessResult, Error>] = [],
        fallback: ProcessResult = .init(exitCode: 1, stdout: "", stderr: "engine unavailable")
    ) {
        stopResult = stop
        self.cancelWait = cancelWait
        self.responses = responses
        self.fallback = fallback
    }

    var actions: [String] { lock.withLock { recordedActions } }
    var requests: [ProcessRequest] { lock.withLock { recordedRequests } }
    var stoppedBundles: [URL] { lock.withLock { bundles } }
    var elapsed: TimeInterval { lock.withLock { time } }

    func stop(bundleURL: URL) async -> DockerDesktopStopResult {
        lock.withLock {
            recordedActions.append("stop")
            bundles.append(bundleURL)
        }
        return stopResult
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = lock.withLock {
            recordedActions.append(request.arguments.first == "desktop" ? "start" : "probe")
            recordedRequests.append(request)
            return responses.isEmpty ? .success(fallback) : responses.removeFirst()
        }
        return try result.get()
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func wait(_ interval: TimeInterval) throws {
        lock.withLock {
            recordedActions.append("wait")
            time += interval
        }
        if cancelWait { throw CancellationError() }
    }
}
