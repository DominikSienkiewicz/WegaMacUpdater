import Foundation

/// Keeps diagnostic output separate from the runner's result buffers and live stream.
/// Only complete lines reach redaction, so a credential split by a pipe read cannot leak.
final class DiagnosticOutputCapture: @unchecked Sendable {
    struct Summary: Sendable {
        let receivedBytes: Int
        let capturedBytes: Int
        let omittedBytes: Int
        let outputBytes: Int
        let truncation: String?
    }

    private static let unterminatedCredential = try? NSRegularExpression(
        pattern: #"(?i)\b(?:token|secret|passphrase|password|passwd|api[_-]?key|access[_-]?key|client[_-]?secret)[^\S\n]*[:=][^\S\n]*(?:"[^"\n]*|'[^'\n]*)(?:\n|$)"#
    )
    private static let partialCredential = try? NSRegularExpression(
        pattern: #"(?i:\bbearer[^\S\n]+\S*)|\b(?:gh[pousr]_|github_pat_|xox[baprsen]-|sk-|AKIA|eyJ)[A-Za-z0-9._~+/=-]*"#
    )

    private let lock = NSLock()
    private let maxOutputBytes: Int
    private let maxPendingBytes: Int
    private let emit: @Sendable (String) -> Void
    private var pending = Data()
    private var insidePEM = false
    private var receivedBytes = 0
    private var capturedBytes = 0
    private var outputBytes = 0
    private var truncation: String?
    private var finished = false

    init(maxOutputBytes: Int = 2 * 1024 * 1024, maxPendingBytes: Int = 64 * 1024,
         emit: @escaping @Sendable (String) -> Void) {
        self.maxOutputBytes = max(0, maxOutputBytes)
        self.maxPendingBytes = max(0, maxPendingBytes)
        self.emit = emit
    }

    func append(_ data: Data) {
        lock.withLock {
            guard !finished else { return }
            receivedBytes += data.count
            guard truncation == nil else { return }
            var output = ""
            for byte in data {
                guard pending.count < maxPendingBytes else {
                    // Stop the whole stream: a discarded long line could hide a PEM start.
                    truncate(reason: "pending_limit")
                    break
                }
                pending.append(byte)
                if byte == 10 {
                    consumePending(final: false, into: &output)
                    if truncation != nil { break }
                }
            }
            if !output.isEmpty { emit(output) }
        }
    }

    func finish() -> Summary {
        lock.withLock {
            if !finished {
                finished = true
                var output = ""
                if truncation == nil, !pending.isEmpty { consumePending(final: true, into: &output) }
                if !output.isEmpty { emit(output) }
            }
            return Summary(receivedBytes: receivedBytes, capturedBytes: capturedBytes,
                           omittedBytes: receivedBytes - capturedBytes, outputBytes: outputBytes, truncation: truncation)
        }
    }

    private func consumePending(final: Bool, into output: inout String) {
        let line = String(decoding: pending, as: UTF8.self)
        let redacted = redact(line, final: final)
        let size = redacted.utf8.count
        guard size <= maxOutputBytes - outputBytes else {
            truncate(reason: "output_limit")
            return
        }
        capturedBytes += pending.count
        outputBytes += size
        pending.removeAll(keepingCapacity: true)
        output += redacted
    }

    private func redact(_ line: String, final: Bool) -> String {
        let marker = line.hasSuffix("\n") ? "[secret]\n" : "[secret]"
        if insidePEM {
            if line.contains("-----END ") { insidePEM = false }
            return ""
        }
        if line.contains("-----BEGIN ") {
            insidePEM = !line.contains("-----END ")
            return marker
        }
        let range = NSRange(line.startIndex..., in: line)
        if Self.unterminatedCredential?.firstMatch(in: line, range: range) != nil { return marker }
        if final, Self.partialCredential?.firstMatch(in: line, range: range) != nil { return marker }
        return LogRedaction.redact(line)
    }

    private func truncate(reason: String) {
        truncation = reason
        pending.removeAll(keepingCapacity: false)
    }
}
