import Foundation
import Testing
@testable import MacUpdaterCore
@testable import WegaHelperKit

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

    // MARK: - Version handshake (per verb, RC3; protocol 9, Z14)

    /// Every verb that changes something. Since protocol 9 each needs a helper that refuses to serve
    /// from a bundle someone other than root can change, so the app never drives an older helper that
    /// launchd may have started from another, unchecked copy of Wega.
    private let actingVerbs = WegaHelperVerb.allCases.filter { $0 != .packageInstallationStatus }

    @Test func handshakeAcceptsMatchingVersion() {
        for verb in WegaHelperVerb.allCases {
            #expect(PrivilegedHelperClient.handshakeOutcome(reported: WegaHelper.version, for: verb) == .compatible, "\(verb)")
        }
    }

    @Test func handshakeRejectsStaleHelper() {
        let stale = WegaHelper.version + "-old"
        for verb in WegaHelperVerb.allCases {
            let accepted = "\(WegaHelper.minimumHelperVersion(for: verb))…\(WegaHelper.version)"
            #expect(
                PrivilegedHelperClient.handshakeOutcome(reported: stale, for: verb, current: WegaHelper.version)
                    == .mismatch(reported: stale, expected: accepted), "\(verb)"
            )
        }
    }

    @Test func eachVerbHasItsOwnMinimumHelperVersion() {
        #expect(WegaHelper.version == "9")
        #expect(Dictionary(uniqueKeysWithValues: WegaHelperVerb.allCases.map { ($0, WegaHelper.minimumHelperVersion(for: $0)) }) == [
            .enableTouchIDForSudo: 9, .beginPackageInstallation: 9, .packageInstallationStatus: 6, .replaceBundle: 9,
            .stageApplicationBundleForTrash: 9, .disableTouchIDForSudo: 9,
        ])
    }

    /// A helper from before protocol 9 (v6 from every released Wega, v7 and v8) still running after the
    /// app updated is sent no acting verb; it still answers where an installation it ran stands, so a
    /// pending self-update can be settled.
    @Test(arguments: ["6", "7", "8"])
    func aHelperBeforeNineIsAskedOnlyAboutAnInstallation(reported: String) throws {
        for verb in actingVerbs {
            #expect(PrivilegedHelperClient.handshakeOutcome(reported: reported, for: verb)
                    == .mismatch(reported: reported, expected: "9…9"), "\(verb)")
            do {
                _ = try PrivilegedHelperClient.acceptedVersion(reported: reported, for: verb)
                Issue.record("a v\(reported) helper must not be sent \(verb)")
            } catch PrivilegedHelperClient.HelperError.versionMismatch(let helper, let expected) {
                #expect(helper == reported && expected == "9…9", "\(verb)")
            }
        }
        #expect(PrivilegedHelperClient.handshakeOutcome(reported: reported, for: .packageInstallationStatus) == .compatible)
        #expect(try PrivilegedHelperClient.acceptedVersion(reported: reported, for: .packageInstallationStatus) == reported)
    }

    /// Only 1–4 ASCII digits in the accepted range: `Int("+7")` is 7, and a newer helper than the
    /// app is never driven.
    @Test func anythingButADigitStringInRangeIsAMismatch() {
        for reported in ["10", "x", "", "+9", " 9", "9 ", "-1", "9-old", "0x9", "00009", "٩", "5"] {
            for verb in WegaHelperVerb.allCases {
                guard case .mismatch(let echoed, _) = PrivilegedHelperClient.handshakeOutcome(reported: reported, for: verb) else {
                    Issue.record("\(reported.debugDescription) must not be compatible for \(verb)")
                    continue
                }
                #expect(echoed == reported)
            }
        }
        #expect(PrivilegedHelperClient.handshakeOutcome(reported: "0009", for: .disableTouchIDForSudo) == .compatible)
    }

    /// Every privileged verb checks the helper's version for itself before its request is sent.
    @Test func everyVerbHandshakesForItselfBeforeItsCall() throws {
        let path = "Sources/MacUpdaterCore/PrivilegedHelper/PrivilegedHelperClient.swift"
        let verbs: [(signature: String, verb: String)] = [
            ("public func enableTouchIDForSudo(", "enableTouchIDForSudo"),
            ("public func disableTouchIDForSudo(", "disableTouchIDForSudo"),
            ("public func replaceBundle(", "replaceBundle"),
            ("public func stageApplicationBundleForTrash(", "stageApplicationBundleForTrash"),
        ]
        for (signature, verb) in verbs {
            let body = try functionBody(signature, in: path)
            let handshake = try #require(body.range(of: "try await performHandshake(for: .\(verb))"), "\(verb)")
            let request = try #require(body.range(of: "call(deadline:"), "\(verb)")
            #expect(handshake.lowerBound < request.lowerBound, "\(verb)")
        }
        let tracked = try functionBody("private var trackedInstaller:", in: path)
        #expect(tracked.contains("handshake: { _ = try await self.performHandshake(for: .beginPackageInstallation) }"))
        #expect(tracked.contains("statusHandshake: { _ = try await self.performHandshake(for: .packageInstallationStatus) }"),
                "settling a pending installation asks only for the status, which a helper before 9 still answers")
        #expect(try functionBody("public func uninstallAvailabilityAfterHandshake(", in: path)
                    .contains("try await performHandshake(for: .stageApplicationBundleForTrash)"))
        #expect(try functionBody("public func availabilityAfterHandshake(for verb:", in: path)
                    .contains("try await performHandshake(for: verb)"))
        let client = try String(contentsOf: packageRoot().appendingPathComponent(path), encoding: .utf8)
        #expect(!client.contains("performHandshake()"), "no handshake without a verb is left")
    }

    @Test func aFailedHandshakeMapsToVerbAvailability() {
        typealias HelperError = PrivilegedHelperClient.HelperError
        let cases: [(error: any Error, expected: HelperVerbAvailability)] = [
            (HelperError.notEnabled, .off),
            (HelperError.versionMismatch(helper: "6", expected: "7…7"), .stale),
            (HelperError.timedOut, .stale),
            (HelperError.connectionFailed, .stale),
            (NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted), .stale),
        ]
        for item in cases {
            #expect(PrivilegedHelperClient.verbAvailability(handshakeFailure: item.error) == item.expected, "\(item.error)")
        }
    }

    // MARK: - Turning Touch ID for sudo on

    @Test func theEnableReplyDecodesKnownCodesOnly() throws {
        let backup = "/etc/pam.d/.sudo_local.wega-backup-0A1B2C3D"
        #expect(try PrivilegedHelperClient.enableReply(code: 1, detail: nil).get() == .enabled)
        #expect(try PrivilegedHelperClient.enableReply(code: 0, detail: nil).get() == .alreadyEnabled)
        #expect(try PrivilegedHelperClient.enableReply(code: -3, detail: nil).get() == .refused(.callerNotAdministrator))
        #expect(try PrivilegedHelperClient.enableReply(code: -20, detail: nil).get() == .restoredAfterFailure)
        #expect(try PrivilegedHelperClient.enableReply(code: -21, detail: nil).get() == .rollbackFailed(backupPath: nil))
        #expect(try PrivilegedHelperClient.enableReply(code: -21, detail: backup).get() == .rollbackFailed(backupPath: backup))
        for (code, detail) in [(-99, nil), (-21, "/tmp/x"), (-8, nil), (2, nil), (1, "/tmp/x"), (0, "/tmp/x")] as [(Int, String?)] {
            guard case .failure(let error) = PrivilegedHelperClient.enableReply(code: code, detail: detail),
                  case .operationFailed(let message) = error as? PrivilegedHelperClient.HelperError else {
                Issue.record("\(code) \(String(describing: detail)) must be an operation failure")
                continue
            }
            #expect(message == "enableTouchIDForSudo failed (\(code))", "only the code is passed on, never the path")
        }
    }

    /// RC2-1: the v8 reply has its own selector, and the client sends only that one.
    @Test func theClientSendsOnlyTheCheckedEnableSelector() throws {
        let body = try functionBody("public func enableTouchIDForSudo(", in: "Sources/MacUpdaterCore/PrivilegedHelper/PrivilegedHelperClient.swift")
        #expect(body.contains("public func enableTouchIDForSudo() async throws -> TouchIDSudoEnableResult"))
        #expect(body.contains("proxy.enableTouchIDForSudoChecked { code, detail in"))
        #expect(body.contains("done(Self.enableReply(code: code, detail: detail))"))
        #expect(!body.contains("proxy.enableTouchIDForSudo {"))
    }

    // MARK: - Turning Touch ID for sudo off

    @Test func disablingWaitsAsLongAsEnabling() {
        #expect(PrivilegedHelperClient.Deadline.disableTouchID == .seconds(60))
    }

    @Test func theDisableReplyDecodesKnownCodesOnly() throws {
        #expect(try PrivilegedHelperClient.disableReply(code: 1, detail: nil).get() == .removed(lines: 1))
        #expect(try PrivilegedHelperClient.disableReply(code: 0, detail: nil).get() == .nothingToRemove)
        #expect(try PrivilegedHelperClient.disableReply(code: -11, detail: nil).get() == .refused(.otherDirectivesPresent))
        #expect(try PrivilegedHelperClient.disableReply(code: -20, detail: nil).get() == .restoredAfterFailure)
        for (code, detail) in [(-99, nil), (-21, "/tmp/x"), (-21, nil), (-12, "/etc/pam.d/.sudo_local.wega-x")] as [(Int, String?)] {
            guard case .failure(let error) = PrivilegedHelperClient.disableReply(code: code, detail: detail),
                  case .operationFailed(let message) = error as? PrivilegedHelperClient.HelperError else {
                Issue.record("\(code) \(String(describing: detail)) must be an operation failure")
                continue
            }
            #expect(!message.contains("/tmp"), "a refused path is never passed on")
        }
    }

    /// Security re-check: a −21 path made by the helper's own live name generator passes the app's
    /// check, so a real failed rollback is shown with its path rather than as an unknown error.
    @Test func aRollbackPathFromTheLiveSwapNameIsAccepted() throws {
        let path = TouchIDSudoDisabler.reportedPath(of: TouchIDSudoDisabler.makeSwapName())
        #expect(try PrivilegedHelperClient.disableReply(code: -21, detail: path).get() == .rollbackFailed(backupPath: path))
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
        let handshake = try #require(
            body.range(of: "try await performHandshake(for: .stageApplicationBundleForTrash)"), "a stale helper must be refused first"
        )
        let request = try #require(body.range(of: "call(deadline: Deadline.stageForTrash)"))
        #expect(handshake.lowerBound < request.lowerBound)
    }

    /// Registration alone is only the first filter; the handshake before the sheet decides whether
    /// the helper can be promised.
    @Test func uninstallUsesTheHelperOnlyWhileItIsRegistered() {
        #expect(PrivilegedHelperClient.uninstallAvailability(isEnabled: true) == .enabled)
        #expect(PrivilegedHelperClient.uninstallAvailability(isEnabled: false) == .off)
    }

    /// A failed handshake never promises the helper: not enabled reads as off, everything else
    /// (stale version, no answer, lost connection, a raw XPC error) as stale.
    @Test func handshakeFailureMapsToAvailability() {
        typealias HelperError = PrivilegedHelperClient.HelperError
        let xpc = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
        let cases: [(error: any Error, expected: UninstallHelperAvailability)] = [
            (HelperError.notEnabled, .off),
            (HelperError.versionMismatch(helper: "5", expected: "6"), .stale),
            (HelperError.timedOut, .stale),
            (HelperError.connectionFailed, .stale),
            (HelperError.operationFailed("x"), .stale),
            (HelperError.teamIDNotConfigured, .stale),
            (xpc, .stale),
        ]
        for item in cases {
            #expect(PrivilegedHelperClient.uninstallAvailability(handshakeFailure: item.error) == item.expected, "\(item.error)")
        }
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
        let handshake = try #require(body.range(of: "try await performHandshake(for: .stageApplicationBundleForTrash)"))
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
