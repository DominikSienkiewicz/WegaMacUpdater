import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Process diagnostics", .serialized)
struct ProcessDiagnosticsTests {
    @Test func successfulRunPersistsSeparateStreamsAndTermination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = Self.request("printf 'out\\n'; printf 'err\\n' >&2")
        let result = try await UpdateDiagnostics.$current.withValue(fixture.run) {
            try await ProcessRunner().run(request)
        }
        let events = fixture.events
        #expect(result == ProcessResult(exitCode: 0, stdout: "out\n", stderr: "err\n"))
        #expect(events.filter { $0.event == "process.stdout" }.compactMap(\.output).joined() == "out\n")
        #expect(events.filter { $0.event == "process.stderr" }.compactMap(\.output).joined() == "err\n")
        let start = try #require(events.first { $0.event == "process.started" })
        let finished = try #require(events.last { $0.event == "process.finished" })
        #expect(start.processID != nil)
        #expect(start.processID == finished.processID)
        #expect(finished.fields["outcome"] == "exited")
        #expect(finished.fields["exit_code"] == "0")
        #expect(finished.fields["termination_reason"] == "exit")
        #expect(Double(finished.fields["elapsed_seconds"] ?? "") != nil)
        #expect(events.first { $0.event == "process.launched" }?.fields["pid"] != nil)
        #expect(finished.fields["stdout_captured_bytes"] == "4")
        #expect(finished.fields["stderr_captured_bytes"] == "4")
    }

    @Test func nonzeroExitPreservesStdoutAndArgumentBoundariesWithoutEnvironment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var request = Self.request("printf '%s' \"$1\"; exit 7", arguments: ["--", "two words"])
        request.environment = ["PRIVATE_ENV": "do-not-persist-this"]
        let result = try await UpdateDiagnostics.$current.withValue(fixture.run) {
            try await ProcessRunner().run(request)
        }
        let events = fixture.events
        #expect(result.exitCode == 7)
        #expect(result.stdout == "two words")
        #expect(events.filter { $0.event == "process.stdout" }.compactMap(\.output).joined() == "two words")
        let start = try #require(events.first { $0.event == "process.started" })
        #expect(start.fields["argument_count"] == String(request.arguments.count))
        for (index, argument) in request.arguments.enumerated() {
            #expect(start.fields["argument_\(index)"] == argument)
        }
        #expect(start.fields["inherit_parent_environment"] == "false")
        #expect(!String(describing: events).contains("do-not-persist-this"))
        #expect(!String(describing: events).contains("PRIVATE_ENV"))
        #expect(events.last { $0.event == "process.finished" }?.fields["exit_code"] == "7")
    }

    @Test func timeoutKeepsPartialOutputBeforeThrowing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var request = Self.request("printf partial; exec /bin/sleep 30")
        request.timeout = 0.3
        await #expect(throws: ProcessRunnerError.timedOut(seconds: 0.3)) {
            try await UpdateDiagnostics.$current.withValue(fixture.run) {
                _ = try await ProcessRunner().run(request)
            }
        }
        #expect(fixture.events.filter { $0.event == "process.stdout" }.compactMap(\.output).joined() == "partial")
        #expect(fixture.events.last { $0.event == "process.finished" }?.fields["outcome"] == "timeout")
    }

    @Test func cancellationKeepsPartialOutputAndOriginalError() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observed = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { observed.continuation.finish() }
            return try await UpdateDiagnostics.$current.withValue(fixture.run) {
                try await ProcessRunner().run(Self.request("printf partial; exec /bin/sleep 30")) { event in
                    if case .stdout = event { observed.continuation.yield(()) }
                }
            }
        }
        for await _ in observed.stream { break }
        task.cancel()
        await #expect(throws: ProcessRunnerError.cancelled) { _ = try await task.value }
        #expect(fixture.events.filter { $0.event == "process.stdout" }.compactMap(\.output).joined() == "partial")
        #expect(fixture.events.last { $0.event == "process.finished" }?.fields["outcome"] == "cancelled")
    }

    @Test func concurrentRunsKeepIndependentCorrelation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await UpdateDiagnostics.$current.withValue(fixture.run) {
            async let first = ProcessRunner().run(Self.request("printf first"))
            async let second = ProcessRunner().run(Self.request("printf second"))
            _ = try await (first, second)
        }
        let events = fixture.events
        let starts = events.filter { $0.event == "process.started" }
        #expect(starts.count == 2)
        #expect(Set(starts.compactMap(\.processID)).count == 2)
        for start in starts {
            let related = events.filter { $0.processID == start.processID }
            #expect(related.filter { $0.event == "process.finished" }.count == 1)
            let output = related.filter { $0.event == "process.stdout" }.compactMap(\.output).joined()
            #expect(output == "first" || output == "second")
            #expect(related.allSatisfy { $0.runID == fixture.run.id })
        }
    }

    @Test func idleTimeoutAndLaunchFailureHaveDistinctOutcomes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var request = Self.request("printf before-idle; exec /bin/sleep 30")
        request.idleTimeout = 0.3
        await #expect(throws: ProcessRunnerError.idleTimedOut(seconds: 0.3)) {
            try await UpdateDiagnostics.$current.withValue(fixture.run) {
                _ = try await ProcessRunner().run(request)
            }
        }
        await #expect(throws: (any Error).self) {
            try await UpdateDiagnostics.$current.withValue(fixture.run) {
                _ = try await ProcessRunner().run(ProcessRequest(executableURL: URL(fileURLWithPath: "/missing-wega-program")))
            }
        }
        let outcomes = fixture.events.filter { $0.event == "process.finished" }.compactMap { $0.fields["outcome"] }
        #expect(outcomes == ["idle_timeout", "launch_failed"])
    }

    @Test func credentialOptionsRedactTheirSeparateValuesWithoutLosingArgumentBoundaries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = Self.request("exit 7", arguments: ["--", "--token", "plain-sensitive-value", "--api-key=inline-sensitive-value", "ordinary"])
        _ = try await UpdateDiagnostics.$current.withValue(fixture.run) {
            try await ProcessRunner().run(request)
        }
        let start = try #require(fixture.events.first { $0.event == "process.started" })
        #expect(start.fields["argument_count"] == String(request.arguments.count))
        #expect(start.fields["argument_3"] == "--token")
        #expect(start.fields["argument_4"] == "[secret]")
        #expect(start.fields["argument_5"] == "--api-key=[secret]")
        #expect(start.fields["argument_6"] == "ordinary")
        #expect(!String(describing: fixture.events).contains("plain-sensitive-value"))
        #expect(!String(describing: fixture.events).contains("inline-sensitive-value"))
    }

    @Test func signalTerminationIsDistinguishedFromANormalExit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try await UpdateDiagnostics.$current.withValue(fixture.run) {
            try await ProcessRunner().run(Self.request("kill -TERM $$"))
        }
        let finished = try #require(fixture.events.last { $0.event == "process.finished" })
        #expect(result.exitCode == 15)
        #expect(finished.fields["termination_reason"] == "signal")
        #expect(finished.fields["termination_signal"] == "15")
    }

    private static func request(_ script: String, arguments: [String] = []) -> ProcessRequest {
        ProcessRequest(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script] + arguments,
                       inheritParentEnvironment: false, timeout: 5, idleTimeout: nil)
    }

    private struct Fixture {
        let directory: URL
        let store: DiagnosticTraceStore
        let run: DiagnosticRun

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("wega-process-trace-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = DiagnosticTraceStore(directory: directory)
            run = DiagnosticRun(trigger: "test", subjects: [], store: store)
        }

        var events: [DiagnosticEvent] { store.events(runID: run.id) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
