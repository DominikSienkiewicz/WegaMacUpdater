import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Diagnostic output capture")
struct DiagnosticOutputCaptureTests {
    @Test func splitCredentialsAndMultibyteCharactersAreAssembledBeforeRedaction() {
        let sink = Sink()
        let capture = DiagnosticOutputCapture(emit: { sink.append($0) })
        let text = "żółw token=top-secret-value\nAuthorization: Bearer abcdefghijklmnop\n"
        for byte in Data(text.utf8) { capture.append(Data([byte])) }
        let summary = capture.finish()
        #expect(sink.text == "żółw token=[secret]\n[secret]\n")
        #expect(summary.capturedBytes == text.utf8.count)
        #expect(summary.omittedBytes == 0)
    }

    @Test func pemMarkersAndBodyNeverReachTheSinkAcrossChunks() {
        let sink = Sink()
        let capture = DiagnosticOutputCapture(emit: { sink.append($0) })
        let text = "before\n-----BEGIN PRIVATE KEY-----\nprivate-key-body\n-----END PRIVATE KEY-----\nafter\n"
        for byte in Data(text.utf8) { capture.append(Data([byte])) }
        _ = capture.finish()
        #expect(sink.text == "before\n[secret]\nafter\n")
        #expect(!sink.text.contains("PRIVATE KEY"))
        #expect(!sink.text.contains("private-key-body"))
    }

    @Test func unfinishedOutputIsSafelyFlushedAndAnOpenPemRemainsSuppressed() {
        let sink = Sink()
        let capture = DiagnosticOutputCapture(emit: { sink.append($0) })
        capture.append(Data("message password=partial-secret".utf8))
        #expect(sink.text.isEmpty)
        _ = capture.finish()
        #expect(sink.text == "message password=[secret]")
        let pemSink = Sink()
        let pem = DiagnosticOutputCapture(emit: { pemSink.append($0) })
        pem.append(Data("-----BEGIN RSA PRIVATE KEY-----\nsecret-unfinished-body".utf8))
        _ = pem.finish()
        #expect(pemSink.text == "[secret]\n")
    }

    @Test func truncatedQuotedCredentialsAndTokenPrefixesAreNotWritten() {
        let sink = Sink()
        let capture = DiagnosticOutputCapture(emit: { sink.append($0) })
        capture.append(Data("password=\"secret with spaces".utf8))
        _ = capture.finish()
        #expect(sink.text == "[secret]")
        #expect(!sink.text.contains("secret with spaces"))
        #expect(!sink.text.contains("with spaces"))
        let tokenSink = Sink()
        let token = DiagnosticOutputCapture(emit: { tokenSink.append($0) })
        token.append(Data("ghp_partial".utf8))
        _ = token.finish()
        #expect(tokenSink.text == "[secret]")
        #expect(!tokenSink.text.contains("ghp_partial"))
    }

    @Test func unfinishedBearerCredentialDoesNotLeakItsShortPrefix() {
        let sink = Sink()
        let capture = DiagnosticOutputCapture(emit: { sink.append($0) })
        capture.append(Data("Bearer abc".utf8))
        _ = capture.finish()
        #expect(sink.text == "[secret]")
    }

    @Test func truncationNeverPublishesPartOfALineOrItsSecret() {
        let sink = Sink()
        let capture = DiagnosticOutputCapture(maxOutputBytes: 16, maxPendingBytes: 32, emit: { sink.append($0) })
        capture.append(Data("ok\n".utf8))
        capture.append(Data("token=secret-that-crosses-the-pending-limit\nmore\n".utf8))
        let summary = capture.finish()
        #expect(sink.text == "ok\n")
        #expect(summary.capturedBytes == 3)
        #expect(summary.omittedBytes == 49)
        #expect(summary.truncation == "pending_limit")
        #expect(summary.outputBytes <= 16)
    }

    @Test func diskOutputLimitCountsRedactedUTF8BytesAndKeepsExactOmissionCount() {
        let sink = Sink()
        let capture = DiagnosticOutputCapture(maxOutputBytes: 8, emit: { sink.append($0) })
        capture.append(Data("żółw\nnext\nlast".utf8))
        let summary = capture.finish()
        #expect(sink.text == "żółw\n")
        #expect(summary.capturedBytes == 8)
        #expect(summary.omittedBytes == 9)
        #expect(summary.outputBytes == 8)
        #expect(summary.truncation == "output_limit")
    }

    @Test func anOverlongLineCannotHideAPemStartAndExposeLaterBody() {
        let sink = Sink()
        let capture = DiagnosticOutputCapture(maxPendingBytes: 16, emit: { sink.append($0) })
        capture.append(Data("abcdefghijklmnop-----BEGIN PRIVATE KEY-----\nbody\n".utf8))
        let summary = capture.finish()
        #expect(sink.text.isEmpty)
        #expect(summary.capturedBytes == 0)
        #expect(summary.omittedBytes > 16)
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [String] = []
        func append(_ chunk: String) { lock.withLock { chunks.append(chunk) } }
        var text: String { lock.withLock { chunks.joined() } }
    }
}
