import Foundation
import Testing
@testable import MacUpdaterCore

/// RC2-3 (Aneks E.4 Q4, E.9): a helper that exits after a minute idle can drop the first connection
/// that reaches it in that instant. The version handshake is idempotent, so the client asks once more
/// when the connection dropped, whether the client's handlers or the proxy's raw XPC error saw it
/// first. Nothing else is asked again: not a timeout, a helper that is off or mismatched, nor a verb.
@Suite("PrivilegedHelper handshake retry")
struct PrivilegedHelperHandshakeRetryTests {
    typealias HelperError = PrivilegedHelperClient.HelperError

    @Test func aDroppedConnectionIsAskedOnceMore() async throws {
        let attempts = Attempts(failing: [HelperError.connectionFailed])

        let version = try await PrivilegedHelperClient.retryingOnceOnConnectionFailure { try attempts.next() }

        #expect(version == "8")
        #expect(attempts.count == 2)
    }

    /// The proxy's error handler passes the raw `NSError` on, and it can win the race against the
    /// interruption and invalidation handlers that map to `.connectionFailed`.
    @Test(arguments: [4097, 4099])
    func aRawInterruptedOrInvalidXPCErrorIsAskedOnceMore(code: Int) async throws {
        let attempts = Attempts(failing: [NSError(domain: NSCocoaErrorDomain, code: code)])

        let version = try await PrivilegedHelperClient.retryingOnceOnConnectionFailure { try attempts.next() }

        #expect(version == "8")
        #expect(attempts.count == 2)
    }

    @Test func aSecondDropIsNotAskedAgain() async {
        let second = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
        let attempts = Attempts(failing: [HelperError.connectionFailed, second, HelperError.connectionFailed])

        await #expect(throws: second) {
            try await PrivilegedHelperClient.retryingOnceOnConnectionFailure { try attempts.next() }
        }
        #expect(attempts.count == 2)
    }

    @Test func nothingElseIsAskedAgain() async {
        let errors: [any Error] = [
            HelperError.timedOut,
            HelperError.notEnabled,
            HelperError.versionMismatch(helper: "7", expected: "8…8"),
            HelperError.operationFailed("helperVersion failed"),
            HelperError.teamIDNotConfigured,
            NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid),
            NSError(domain: NSPOSIXErrorDomain, code: 4097),
            CancellationError(),
        ]
        for error in errors {
            let attempts = Attempts(failing: [error, error])
            do {
                _ = try await PrivilegedHelperClient.retryingOnceOnConnectionFailure { try attempts.next() }
                Issue.record("\(error) must be thrown")
            } catch let thrown {
                #expect(String(reflecting: thrown) == String(reflecting: error))
            }
            #expect(attempts.count == 1, "\(error) must not be asked again")
        }
    }

    @Test func aDroppedConnectionIsExactlyTheseThreeErrors() {
        #expect(NSXPCConnectionInterrupted == 4097)
        #expect(NSXPCConnectionInvalid == 4099)
        #expect(PrivilegedHelperClient.isDroppedConnection(HelperError.connectionFailed))
        #expect(PrivilegedHelperClient.isDroppedConnection(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)))
        #expect(PrivilegedHelperClient.isDroppedConnection(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)))
        #expect(PrivilegedHelperClient.isDroppedConnection(CocoaError(.xpcConnectionInterrupted)))
        #expect(!PrivilegedHelperClient.isDroppedConnection(HelperError.timedOut))
        #expect(!PrivilegedHelperClient.isDroppedConnection(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid)))
        #expect(!PrivilegedHelperClient.isDroppedConnection(NSError(domain: NSPOSIXErrorDomain, code: 4099)))
    }

    /// The retry wraps only the version probe. A verb can have run on the helper before its
    /// connection dropped, so it is never sent twice.
    @Test func onlyTheHandshakeIsAskedAgain() throws {
        let client = try String(contentsOf: packageRoot().appendingPathComponent(Self.clientPath), encoding: .utf8)
        #expect(client.components(separatedBy: "retryingOnceOnConnectionFailure").count - 1 == 2, "one definition, one use")
        let handshake = try functionBody("public func helperVersion() async throws -> String", in: client)
        #expect(handshake.contains("try await Self.retryingOnceOnConnectionFailure {"))
        #expect(handshake.contains("call(deadline: Deadline.handshake)"))
        for signature in [
            "public func enableTouchIDForSudo(",
            "public func disableTouchIDForSudo(",
            "public func replaceBundle(",
            "public func stageApplicationBundleForTrash(",
            "private func installationReply(",
            "private func call<",
        ] {
            let body = try functionBody(signature, in: client)
            #expect(!body.lowercased().contains("retry"), "\(signature) must not ask again")
        }
    }

    // MARK: - Helpers

    private static let clientPath = "Sources/MacUpdaterCore/PrivilegedHelper/PrivilegedHelperClient.swift"

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// From `signature` to the closing brace at the function's own indentation.
    private func functionBody(_ signature: String, in text: String) throws -> Substring {
        let start = try #require(text.range(of: signature), "\(signature) must exist")
        let end = text[start.upperBound...].range(of: "\n    }\n")?.upperBound ?? text.endIndex
        return text[start.lowerBound..<end]
    }
}

/// Answers "8" after throwing `failing`, one error per attempt, and counts the attempts.
private final class Attempts {
    private var failing: [any Error]
    private(set) var count = 0

    init(failing: [any Error]) {
        self.failing = failing
    }

    func next() throws -> String {
        count += 1
        guard failing.isEmpty else { throw failing.removeFirst() }
        return "8"
    }
}
