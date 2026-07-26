import Foundation
import Testing
@testable import MacUpdaterCore

/// SEC-10: the privileged client must never hang on a dead/unresponsive helper,
/// and must refuse to drive a version-mismatched (stale) one. These pin the two
/// mechanisms that guarantee it — the XPC reply deadline and the version
/// handshake decision — without needing a live root daemon.
@Suite("PrivilegedHelper deadline & handshake")
struct PrivilegedHelperDeadlineTests {

    // MARK: - Deadline (no hang on a dead helper)

    @Test func unresponsiveHelperReplyTimesOutInsteadOfHanging() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let _: String = try await awaitReplyWithDeadline(timeout: .milliseconds(100)) { _ in
                // Simulate a dead helper: the reply callback is never invoked.
            }
            Issue.record("expected the deadline to fire, not a value")
        } catch let error as PrivilegedHelperClient.HelperError {
            guard case .timedOut = error else {
                Issue.record("expected .timedOut, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        // A hang would never reach this line; the bound proves it resolved promptly.
        #expect(clock.now - start < .seconds(3))
    }

    @Test func replyBeforeDeadlineReturnsValueAndSkipsTimeout() async throws {
        let flag = TimeoutFlag()
        let value: Int = try await awaitReplyWithDeadline(
            timeout: .seconds(30),
            onTimeout: { flag.mark() }
        ) { done in
            done(.success(7))
        }
        #expect(value == 7)
        #expect(flag.fired == false)
    }

    @Test func errorReplyPropagatesBeforeDeadline() async {
        struct Boom: Error {}
        do {
            let _: Int = try await awaitReplyWithDeadline(timeout: .seconds(30)) { done in
                done(.failure(Boom()))
            }
            Issue.record("expected the error to propagate")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - Version handshake

    @Test func handshakeAcceptsMatchingVersion() {
        #expect(PrivilegedHelperClient.handshakeOutcome(reported: WegaHelper.version) == .compatible)
    }

    @Test func handshakeRejectsStaleHelper() {
        let stale = WegaHelper.version + "-old"
        #expect(
            PrivilegedHelperClient.handshakeOutcome(reported: stale, expected: WegaHelper.version)
                == .mismatch(reported: stale, expected: WegaHelper.version)
        )
    }
}

/// Thread-safe one-shot flag for observing whether the deadline's `onTimeout`
/// fired from a concurrent task.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var fired: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
