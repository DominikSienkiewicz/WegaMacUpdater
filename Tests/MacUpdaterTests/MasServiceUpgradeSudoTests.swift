import XCTest
@testable import MacUpdaterCore

/// Why: `mas upgrade` invokes `sudo softwareupdate …` internally for Safari
/// extensions and similar MAS items, **with an absolute `/usr/bin/sudo`
/// path** that bypasses our PATH shim. Result without intervention:
///
///     sudo: a terminal is required to read the password;
///     either use the -S option … or configure an askpass helper
///
/// Strategy: on first attempt, if `mas upgrade` exits non-zero with that
/// exact stderr signature, MasService runs `/usr/bin/sudo -A -v` once to
/// prime the no-tty sudo timestamp (the askpass dialog renders, user
/// authenticates), then retries `mas upgrade` — mas's internal sudo call
/// now finds a valid cached credential and skips the prompt.
final class MasServiceUpgradeSudoTests: XCTestCase {

    private let masURL = URL(fileURLWithPath: "/usr/bin/true")
    private var locator: BinaryLocator { BinaryLocator(masCandidates: [masURL]) }

    func testUpgradePrewarmsSudoAndRetriesOnTerminalRequiredError() async throws {
        let runner = QueuingProcessRunner(responses: [
            // 1. mas upgrade — fails with the canonical sudo-tty error
            ProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper\nsudo: a password is required\n"
            ),
            // 2. sudo -A -v — askpass succeeds, timestamp cached
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            // 3. mas upgrade retry — clean
            ProcessResult(exitCode: 0, stdout: "Upgrading Proton Pass for Safari\n", stderr: "")
        ])

        let service = MasService(locator: locator, runner: runner)

        let result = try await service.upgrade()
        XCTAssertEqual(result.exitCode, 0)

        XCTAssertEqual(runner.requests.count, 3, "expected first mas → sudo -A -v → retry mas, got \(runner.requests.map { $0.executableURL.lastPathComponent + " " + $0.arguments.joined(separator: " ") })")

        XCTAssertEqual(runner.requests[0].executableURL, masURL)
        XCTAssertEqual(runner.requests[0].arguments, ["upgrade"])

        XCTAssertEqual(runner.requests[1].executableURL.path, "/usr/bin/sudo",
                       "Prewarm must invoke the real /usr/bin/sudo, not the PATH-shim, so it matches what mas uses internally.")
        XCTAssertEqual(runner.requests[1].arguments, ["-A", "-v"])

        XCTAssertEqual(runner.requests[2].executableURL, masURL)
        XCTAssertEqual(runner.requests[2].arguments, ["upgrade"])
    }

    func testUpgradeDoesNotPrewarmOnSuccess() async throws {
        let runner = QueuingProcessRunner(responses: [
            ProcessResult(exitCode: 0, stdout: "Nothing to upgrade\n", stderr: "")
        ])
        let service = MasService(locator: locator, runner: runner)

        _ = try await service.upgrade()

        XCTAssertEqual(runner.requests.count, 1,
                       "Happy path must not trigger a sudo askpass dialog when no sudo error occurred.")
    }

    func testUpgradeDoesNotPrewarmOnUnrelatedFailure() async {
        // A non-sudo failure should still surface as an error — no retry, no
        // gratuitous sudo prompt.
        let runner = QueuingProcessRunner(responses: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "Error: network unreachable\n")
        ])
        let service = MasService(locator: locator, runner: runner)

        do {
            _ = try await service.upgrade()
            XCTFail("Expected commandFailed")
        } catch MasServiceError.commandFailed {
            XCTAssertEqual(runner.requests.count, 1)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testUpgradePropagatesRetryFailure() async {
        // If the retry also fails (e.g. user dismissed askpass), surface the
        // failure — do not loop forever.
        let runner = QueuingProcessRunner(responses: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "sudo: a terminal is required to read the password\n"),
            ProcessResult(exitCode: 1, stdout: "", stderr: "askpass cancelled\n"), // sudo -A -v fails
            ProcessResult(exitCode: 1, stdout: "", stderr: "sudo: a password is required\n")
        ])
        let service = MasService(locator: locator, runner: runner)

        do {
            _ = try await service.upgrade()
            XCTFail("Expected commandFailed")
        } catch MasServiceError.commandFailed {
            // expected — and we attempted exactly one retry, not more
            XCTAssertLessThanOrEqual(runner.requests.count, 3)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}

private final class QueuingProcessRunner: ProcessRunning, @unchecked Sendable {
    private var responses: [ProcessResult]
    private(set) var requests: [ProcessRequest] = []
    private let lock = NSLock()

    init(responses: [ProcessResult]) { self.responses = responses }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        guard !responses.isEmpty else {
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        return responses.removeFirst()
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
