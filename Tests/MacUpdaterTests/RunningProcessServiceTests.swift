import Testing
import Foundation
@testable import MacUpdaterCore

/// Records every request and returns a programmable exit code.
private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ProcessRequest] = []
    private let exitCode: Int32

    init(exitCode: Int32 = 0) { self.exitCode = exitCode }

    var requests: [ProcessRequest] { lock.withLock { _requests } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { _requests.append(request) }
        return ProcessResult(exitCode: exitCode, stdout: "", stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("RunningProcessService")
struct RunningProcessServiceTests {
    private let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
    private let killall = URL(fileURLWithPath: "/usr/bin/killall")
    private let open = URL(fileURLWithPath: "/usr/bin/open")

    @Test func isRunningTrueWhenPgrepExitsZero() async {
        let runner = RecordingRunner(exitCode: 0)
        let service = RunningProcessService(runner: runner, pgrepURL: pgrep, killallURL: killall, openURL: open)

        let running = await service.isRunning("zoom.us")

        #expect(running == true)
        #expect(runner.requests.count == 1)
        #expect(runner.requests[0].executableURL == pgrep)
        #expect(runner.requests[0].arguments == ["-x", "zoom.us"])
    }

    @Test func isRunningFalseWhenPgrepExitsNonZero() async {
        let runner = RecordingRunner(exitCode: 1)
        let service = RunningProcessService(runner: runner, pgrepURL: pgrep, killallURL: killall, openURL: open)

        let running = await service.isRunning("zoom.us")

        #expect(running == false)
    }

    @Test func killInvokesKillallWithProcessName() async {
        let runner = RecordingRunner()
        let service = RunningProcessService(runner: runner, pgrepURL: pgrep, killallURL: killall, openURL: open)

        await service.kill("zoom.us")

        #expect(runner.requests.count == 1)
        #expect(runner.requests[0].executableURL == killall)
        #expect(runner.requests[0].arguments == ["zoom.us"])
    }

    @Test func launchInvokesOpenWithAppName() async {
        let runner = RecordingRunner()
        let service = RunningProcessService(runner: runner, pgrepURL: pgrep, killallURL: killall, openURL: open)

        await service.launch(appName: "zoom.us")

        #expect(runner.requests.count == 1)
        #expect(runner.requests[0].executableURL == open)
        #expect(runner.requests[0].arguments == ["-a", "zoom.us"])
    }
}
