import Foundation
import Testing
@testable import MacUpdaterCore

private final class TerminationRecordingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let exitCode: Int32
    private var recordedRequests: [ProcessRequest] = []

    init(exitCode: Int32) {
        self.exitCode = exitCode
    }

    var requests: [ProcessRequest] {
        lock.withLock { recordedRequests }
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { recordedRequests.append(request) }
        return ProcessResult(exitCode: exitCode, stdout: "", stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class RecordingApplicationTerminator: ApplicationTerminating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Bool
    private var recordedRequests: [(appName: String, processName: String)] = []

    init(result: Bool) {
        self.result = result
    }

    var requests: [(appName: String, processName: String)] {
        lock.withLock { recordedRequests }
    }

    @MainActor
    func requestTermination(appName: String, processName: String) -> Bool {
        lock.withLock { recordedRequests.append((appName, processName)) }
        return result
    }
}

@Suite("Running process termination")
struct RunningProcessTerminationTests {
    private let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
    private let killall = URL(fileURLWithPath: "/usr/bin/killall")
    private let open = URL(fileURLWithPath: "/usr/bin/open")

    @Test func gracefulTerminationUsesTheNativeApplicationRequest() async {
        let runner = TerminationRecordingRunner(exitCode: 0)
        let terminator = RecordingApplicationTerminator(result: true)
        let service = makeService(runner: runner, terminator: terminator)

        let requested = await service.requestGracefulTermination(
            appName: "Visual Studio Code",
            processName: "Code"
        )

        #expect(requested)
        #expect(terminator.requests.count == 1)
        #expect(terminator.requests.first?.appName == "Visual Studio Code")
        #expect(terminator.requests.first?.processName == "Code")
        #expect(runner.requests.isEmpty)
    }

    @Test func gracefulTerminationReturnsTheNativeRequestResult() async {
        let runner = TerminationRecordingRunner(exitCode: 0)
        let terminator = RecordingApplicationTerminator(result: false)
        let service = makeService(runner: runner, terminator: terminator)

        let requested = await service.requestGracefulTermination(appName: "Acme", processName: "Acme")

        #expect(!requested)
    }

    @Test func forceKillReportsFailureAndUsesAnExplicitKillSignal() async {
        let runner = TerminationRecordingRunner(exitCode: 1)
        let service = makeService(
            runner: runner,
            terminator: RecordingApplicationTerminator(result: true)
        )

        let terminated = await service.forceKill("zoom.us")

        #expect(!terminated)
        #expect(runner.requests == [ProcessRequest(
            executableURL: killall,
            arguments: ["-KILL", "zoom.us"]
        )])
    }

    private func makeService(
        runner: TerminationRecordingRunner,
        terminator: RecordingApplicationTerminator
    ) -> RunningProcessService {
        RunningProcessService(
            runner: runner,
            pgrepURL: pgrep,
            killallURL: killall,
            openURL: open,
            applicationTerminator: terminator
        )
    }
}
