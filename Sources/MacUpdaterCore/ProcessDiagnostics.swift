import Foundation

/// Explicitly retained by pipe callbacks; TaskLocal context does not follow Foundation callbacks.
final class ProcessDiagnostics: @unchecked Sendable {
    private static let credentialOptions: Set<String> = [
        "--token", "--secret", "--password", "--passwd", "--passphrase", "--api-key", "--api_key", "--apikey",
        "--access-key", "--access_key", "--client-secret", "--client_secret", "--access-token", "--auth-token",
        "--refresh-token", "--authorization", "--proxy-authorization",
    ]

    let command: String
    private let run: DiagnosticRun
    private let processID = UUID()
    private let started = DispatchTime.now()
    private let lock = NSLock()
    private let stdout: DiagnosticOutputCapture
    private let stderr: DiagnosticOutputCapture
    private var finished = false

    init(run: DiagnosticRun, request: ProcessRequest) {
        self.run = run
        let arguments = Self.redactedArguments(request.arguments)
        command = ([request.executableURL.lastPathComponent] + arguments).joined(separator: " ")
        let identifier = processID
        stdout = DiagnosticOutputCapture { output in
            run.record("process.stdout", processID: identifier, output: output)
        }
        stderr = DiagnosticOutputCapture { output in
            run.record("process.stderr", processID: identifier, output: output)
        }
        var fields = [
            "executable": request.executableURL.path,
            "command": request.executableURL.lastPathComponent,
            "argument_count": String(request.arguments.count),
            "inherit_parent_environment": String(request.inheritParentEnvironment),
            "timeout_seconds": request.timeout.map { String($0) } ?? "none",
            "idle_timeout_seconds": request.idleTimeout.map { String($0) } ?? "none",
        ]
        for (index, argument) in arguments.enumerated() { fields["argument_\(index)"] = argument }
        run.record("process.started", fields: fields, processID: processID)
    }

    func launched(_ process: Process) {
        run.record("process.launched", fields: ["pid": String(process.processIdentifier),
                                               "launch_elapsed_seconds": elapsed], processID: processID)
    }

    func appendStdout(_ data: Data) { stdout.append(data) }
    func appendStderr(_ data: Data) { stderr.append(data) }

    func finishBeforeLaunch(error: Error) {
        finish(outcome: error is CancellationError ? "cancelled" : "launch_failed", error: error)
    }

    func finish(outcome: String, process: Process? = nil, error: Error? = nil) {
        let shouldFinish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        var fields = ["outcome": outcome, "elapsed_seconds": elapsed]
        appendSummary(stdout.finish(), stream: "stdout", to: &fields)
        appendSummary(stderr.finish(), stream: "stderr", to: &fields)
        if let process, process.processIdentifier > 0 {
            fields["pid"] = String(process.processIdentifier)
            if !process.isRunning {
                fields["exit_code"] = String(process.terminationStatus)
                fields["termination_reason"] = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
                if process.terminationReason == .uncaughtSignal {
                    fields["termination_signal"] = String(process.terminationStatus)
                }
            }
        }
        if let error {
            fields["error"] = error.localizedDescription
            fields["error_domain"] = (error as NSError).domain
            fields["error_code"] = String((error as NSError).code)
        }
        run.record("process.finished", fields: fields, processID: processID)
    }

    private static func redactedArguments(_ arguments: [String]) -> [String] {
        var expectsCredential = false
        return arguments.map { argument in
            let credentialOption = credentialOptions.contains(argument.lowercased())
            if expectsCredential, !credentialOption {
                expectsCredential = false
                return "[secret]"
            }
            expectsCredential = credentialOption
            return LogRedaction.redact(argument)
        }
    }

    private var elapsed: String {
        String(Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000_000)
    }

    private func appendSummary(_ summary: DiagnosticOutputCapture.Summary, stream: String, to fields: inout [String: String]) {
        fields["\(stream)_received_bytes"] = String(summary.receivedBytes)
        fields["\(stream)_captured_bytes"] = String(summary.capturedBytes)
        fields["\(stream)_omitted_bytes"] = String(summary.omittedBytes)
        fields["\(stream)_output_bytes"] = String(summary.outputBytes)
        if summary.omittedBytes > 0 {
            run.record("process.output_truncated", fields: ["stream": stream, "omitted_bytes": String(summary.omittedBytes),
                                                        "reason": summary.truncation ?? "incomplete"], processID: processID)
        }
    }
}
