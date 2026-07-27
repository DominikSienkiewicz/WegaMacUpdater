import XCTest
@testable import MacUpdaterCore

/// ARCH-03: the global-npm outdated scan must run a single `npm outdated -g --json`
/// process (no `npm view` fan-out) and must report npm failures instead of swallowing
/// them into a falsely-successful empty result.
final class NpmGlobalServiceOutdatedTests: XCTestCase {
    private func service(_ runner: ProcessRunning) -> NpmGlobalService {
        // Resolve npm to a real executable so `locate()` never falls through to a
        // login-shell spawn — the only process observed is the npm command itself.
        NpmGlobalService(
            locator: NpmLocator(extraCandidates: [URL(fileURLWithPath: "/bin/echo")]),
            runner: runner
        )
    }

    func testOutdatedRunsExactlyOneNpmOutdatedProcess() async throws {
        let runner = RecordingProcessRunner(result: ProcessResult(exitCode: 0, stdout: "{}", stderr: ""))

        _ = try await service(runner).outdated()

        XCTAssertEqual(runner.requests.count, 1)
        XCTAssertEqual(runner.requests.first?.arguments, ["outdated", "-g", "--json"])
    }

    func testOutdatedParsesPackagesEvenWhenNpmExitsNonZero() async throws {
        // `npm outdated` exits 1 precisely because packages are outdated — that is a
        // successful scan, not a failure.
        let json = #"{"pnpm":{"current":"9.0.0","wanted":"10.0.0","latest":"10.0.0"}}"#
        let runner = RecordingProcessRunner(result: ProcessResult(exitCode: 1, stdout: json, stderr: ""))

        let out = try await service(runner).outdated()

        XCTAssertEqual(out.map(\.name), ["pnpm"])
        XCTAssertEqual(out.first?.installedVersion, "9.0.0")
        XCTAssertEqual(out.first?.latestVersion, "10.0.0")
    }

    func testOutdatedReturnsEmptyWhenNothingIsOutdated() async throws {
        let runner = RecordingProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))

        let out = try await service(runner).outdated()

        XCTAssertTrue(out.isEmpty)
    }

    func testOutdatedThrowsOnNpmErrorPayloadInsteadOfReturningEmpty() async {
        // Registry/network failure: npm prints `{"error": {...}}`. The scan must surface
        // it (throw) so the caller marks npm failed — not report a silent empty success.
        let errorJSON = #"{"error":{"code":"E404","summary":"registry unreachable","detail":"…"}}"#
        let runner = RecordingProcessRunner(result: ProcessResult(exitCode: 1, stdout: errorJSON, stderr: "npm ERR! 404"))

        do {
            let out = try await service(runner).outdated()
            XCTFail("expected outdated() to throw on npm error payload, got \(out)")
        } catch {
            // expected
        }
    }

    func testOutdatedThrowsWhenNpmFailsWithoutUsableJSON() async {
        let runner = RecordingProcessRunner(
            result: ProcessResult(exitCode: 1, stdout: "npm ERR! something broke", stderr: "boom")
        )

        do {
            let out = try await service(runner).outdated()
            XCTFail("expected outdated() to throw on unparseable failure output, got \(out)")
        } catch {
            // expected
        }
    }

    func testPackageLiterallyNamedErrorIsNotMistakenForAnNpmFailure() async throws {
        // A published package named "error" carries version fields, unlike npm's error
        // object — the scan must treat it as a normal outdated entry.
        let json = #"{"error":{"current":"1.0.0","wanted":"2.0.0","latest":"2.0.0"}}"#
        let runner = RecordingProcessRunner(result: ProcessResult(exitCode: 1, stdout: json, stderr: ""))

        let out = try await service(runner).outdated()

        XCTAssertEqual(out.map(\.name), ["error"])
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProcessRequest] = []
    private let result: ProcessResult

    init(result: ProcessResult) { self.result = result }

    var requests: [ProcessRequest] { lock.withLock { recorded } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { recorded.append(request) }
        return result
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
