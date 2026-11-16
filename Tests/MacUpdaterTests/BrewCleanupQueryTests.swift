import Foundation
import XCTest
@testable import MacUpdaterCore

final class BrewCleanupQueryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        HomebrewEnvironment.touchIDStateOverride = .enabled
    }

    override func tearDown() {
        HomebrewEnvironment.touchIDStateOverride = nil
        super.tearDown()
    }

    func testUsesInstalledSendsFencedNameWithNoAutoUpdate() async throws {
        let runner = QueryRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        _ = try await makeService(runner).usesInstalled(formula: "python@3.15")
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.arguments, ["uses", "--installed", "--", "python@3.15"])
        XCTAssertEqual(request.environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(request.environment["HOMEBREW_NO_ANALYTICS"], "1")
        XCTAssertEqual(request.environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
        XCTAssertFalse(request.inheritParentEnvironment)
    }

    func testUsesInstalledParsesOneDependentPerLine() async throws {
        let runner = QueryRunner(
            result: ProcessResult(exitCode: 0, stdout: "ollama\nmlx\n\nnmap\nmlx-c\n", stderr: "")
        )
        let dependents = try await makeService(runner).usesInstalled(formula: "python@3.15")
        XCTAssertEqual(dependents, ["mlx", "mlx-c", "nmap", "ollama"])
    }

    func testUninstallFormulaFencesTheName() async throws {
        let runner = QueryRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        _ = try await makeService(runner).uninstallFormula(name: "gh")
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.arguments, ["uninstall", "--formula", "--", "gh"])
        XCTAssertEqual(request.environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
        XCTAssertNil(request.environment["HOMEBREW_NO_AUTO_UPDATE"])

        let failing = QueryRunner(result: ProcessResult(exitCode: 1, stdout: "", stderr: "boom"))
        do {
            _ = try await makeService(failing).uninstallFormula(name: "gh")
            XCTFail("A non-zero exit must throw")
        } catch BrewServiceError.commandFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// The confirmation sheet and the text export show this text as the command Cleanup runs.
    func testCleanupCommandTextIsWhatBrewServiceRuns() async throws {
        let runner = QueryRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let removal = BrewServiceCleanupRemoval(brew: makeService(runner))

        try await removal.uninstallFormula(name: "gh")
        try await removal.uninstallCask(token: "claude-code")

        XCTAssertEqual(runner.requests.map { (["brew"] + $0.arguments).joined(separator: " ") }, [
            CleanupActionText.command(for: .uninstallFormula("gh")),
            CleanupActionText.command(for: .uninstallCask("claude-code")),
        ])
        XCTAssertEqual(CleanupActionText.command(for: .uninstallFormula("gh")), "brew uninstall --formula -- gh")
        XCTAssertEqual(CleanupActionText.command(for: .uninstallCask("claude-code")), "brew uninstall --cask -- claude-code")
    }

    func testSanitizedEnvironmentAdmitsCleanupQueryKeys() {
        let sanitized = AuthorizationEnvironment.sanitized(
            inherited: [:],
            overrides: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "EVIL": "1"]
        )
        XCTAssertEqual(sanitized["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(sanitized["HOMEBREW_NO_ANALYTICS"], "1")
        XCTAssertNil(sanitized["EVIL"])
    }

    private func makeService(_ runner: QueryRunner) -> BrewService {
        BrewService(
            locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]), runner: runner
        )
    }
}

private final class QueryRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProcessRequest] = []
    private let result: ProcessResult
    var requests: [ProcessRequest] { lock.withLock { storage } }

    init(result: ProcessResult) { self.result = result }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { storage.append(request) }
        return result
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        lock.withLock { storage.append(request) }
        return AsyncThrowingStream { $0.finish() }
    }
}
