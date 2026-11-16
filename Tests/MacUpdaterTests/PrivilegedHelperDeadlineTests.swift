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
            let _: String = try await awaitReplyWithDeadline(timeout: .milliseconds(100), body: { _ in
                // Simulate a dead helper: the reply callback is never invoked.
            })
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
            onTimeout: { flag.mark() },
            body: { done in done(.success(7)) }
        )
        #expect(value == 7)
        #expect(flag.fired == false)
    }

    @Test func errorReplyPropagatesBeforeDeadline() async {
        struct Boom: Error {}
        do {
            let _: Int = try await awaitReplyWithDeadline(timeout: .seconds(30), body: { done in
                done(.failure(Boom()))
            })
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

    // MARK: - Staging a root-owned app for the Trash (Uninstall)

    /// The helper walks the whole bundle under a lock, so a large app takes a while: the wait is
    /// generous, but it still ends, so a dead helper never leaves Uninstall hanging.
    @Test func stagingDeadlineIsBounded() {
        let deadline = PrivilegedHelperClient.Deadline.stageForTrash
        #expect(deadline >= .seconds(300), "a large bundle must have time to be handed over")
        #expect(deadline <= PrivilegedHelperClient.Deadline.replaceBundle, "the wait stays bounded")
    }

    @Test func stagingCallHandshakesFirstAndWaitsOnItsOwnDeadline() throws {
        let body = try functionBody(
            "public func stageApplicationBundleForTrash(",
            in: "Sources/MacUpdaterCore/PrivilegedHelper/PrivilegedHelperClient.swift"
        )
        let handshake = try #require(body.range(of: "try await performHandshake()"), "a stale helper must be refused first")
        let request = try #require(body.range(of: "call(deadline: Deadline.stageForTrash)"))
        #expect(handshake.lowerBound < request.lowerBound)
    }

    /// Uninstall reads only whether the helper is registered; a stale helper is found when it is
    /// called, never by a synchronous handshake while the confirmation sheet is built.
    @Test func uninstallUsesTheHelperOnlyWhileItIsRegistered() {
        #expect(PrivilegedHelperClient.uninstallAvailability(isEnabled: true) == .enabled)
        #expect(PrivilegedHelperClient.uninstallAvailability(isEnabled: false) == .off)
    }

    /// A path with a note means the bundle left /Applications but some items stayed root-owned;
    /// it is still the staged bundle the app then moves to the Trash.
    @Test func aStagedPathIsTheResultWithOrWithoutAHandOverNote() throws {
        let staged = "/Library/Application Support/com.wega.WegaMacUpdater/UninstallStaging/A/Foo.app"
        let complete = PrivilegedHelperClient.stagingReply(stagedPath: staged, note: nil)
        let partial = PrivilegedHelperClient.stagingReply(stagedPath: staged, note: "2 items stayed root-owned")

        #expect(try complete.get() == URL(fileURLWithPath: staged))
        #expect(try partial.get() == URL(fileURLWithPath: staged))
    }

    @Test func noStagedPathIsTheHelpersRefusalWithItsMessage() {
        let refusal = PrivilegedHelperClient.stagingReply(stagedPath: nil, note: "Aplikacja nie należy do roota.")
        let silent = PrivilegedHelperClient.stagingReply(stagedPath: nil, note: nil)

        #expect(operationFailure(refusal) == "Aplikacja nie należy do roota.")
        #expect(operationFailure(silent)?.isEmpty == false, "a refusal without a note still says what failed")
    }

    /// Ruling 19: a failure of the handshake is marked as not sent, and a failure of the staging
    /// request itself as sent, so Uninstall can tell "reinstall the helper" (nothing happened)
    /// from "the app may already have left /Applications".
    @Test func stagingFailuresSayWhetherTheRequestWasSent() throws {
        let body = try functionBody(
            "public func stageApplicationBundleForTrash(",
            in: "Sources/MacUpdaterCore/PrivilegedHelper/PrivilegedHelperClient.swift"
        )
        let handshake = try #require(body.range(of: "try await performHandshake()"))
        let notSent = try #require(body.range(of: "StagingFailure(underlying: error, requestSent: false)"))
        let request = try #require(body.range(of: "call(deadline: Deadline.stageForTrash)"))
        let sent = try #require(body.range(of: "StagingFailure(underlying: error, requestSent: true)"))

        #expect(handshake.upperBound < notSent.lowerBound)
        #expect(body[handshake.upperBound..<notSent.lowerBound].contains("catch"),
                "the handshake's own failure must be caught and marked as not sent")
        #expect(notSent.upperBound < request.lowerBound)
        #expect(body[request.upperBound..<sent.lowerBound].contains("catch"))
    }

    private func operationFailure(_ result: Result<URL, Error>) -> String? {
        guard case .failure(let error) = result,
              case .operationFailed(let message) = error as? PrivilegedHelperClient.HelperError
        else { return nil }
        return message
    }

    // MARK: - Source access

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The text of the function starting at `signature`, up to the closing brace at its own
    /// indentation.
    private func functionBody(_ signature: String, in relativePath: String) throws -> Substring {
        let text = try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
        let start = try #require(text.range(of: signature), "\(signature) must exist")
        let end = text[start.upperBound...].range(of: "\n    }\n")?.upperBound ?? text.endIndex
        return text[start.lowerBound..<end]
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
