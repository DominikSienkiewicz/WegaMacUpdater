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

    func testCleanupDryRunParsesPathsAndBinarySizes() {
        let stdout = """
        Would remove: /opt/homebrew/Cellar/node/22.1.0 (2,345 files, 60.1MB)
        Would remove: /Users/t/Library/Caches/Homebrew/downloads/ab12--node--22.1.0.arm64_tahoe.bottle.tar.gz (21.5MB)
        Would remove: /Users/t/Library/Logs/Homebrew/node (64B)
        Would prune: /opt/homebrew/share/broken-link
        Warning: something unrelated
        ==> This operation would free approximately 81.6MB of disk space.
        """
        let items = BrewService.parseCleanupDryRun(stdout)
        XCTAssertEqual(items.map(\.path.path), [
            "/opt/homebrew/Cellar/node/22.1.0",
            "/Users/t/Library/Caches/Homebrew/downloads/ab12--node--22.1.0.arm64_tahoe.bottle.tar.gz",
            "/Users/t/Library/Logs/Homebrew/node"
        ])
        XCTAssertEqual(items.map(\.size), [Int64(60.1 * 1_048_576), Int64(21.5 * 1_048_576), 64])
    }

    func testCleanupDryRunSkipsUnparseableLinesAndToleratesAnUnknownSize() {
        let stdout = "Would remove: /a/b (weird)\nWould remove: nothing here\nWould remove: /c/d (1.5KB)\n"
        let items = BrewService.parseCleanupDryRun(stdout)
        XCTAssertEqual(items.map(\.path.path), ["/a/b", "/c/d"])
        XCTAssertEqual(items.map(\.size), [nil, 1_536])
    }

    func testAutoremoveDryRunListsOneFormulaPerLine() {
        let stdout = "==> Would autoremove 2 unneeded formulae:\nlibfoo\nuser/tap/libbar\n"
        XCTAssertEqual(BrewService.parseAutoremoveDryRun(stdout), ["libfoo", "user/tap/libbar"])
        XCTAssertEqual(BrewService.parseAutoremoveDryRun(""), [])
    }

    func testArgumentsFenceNamesAndNeverRunGlobally() {
        XCTAssertEqual(BrewService.cleanupPackageArguments(name: "node"), ["cleanup", "--", "node"])
        XCTAssertEqual(BrewService.cleanupDryRunArguments(package: nil), ["cleanup", "--dry-run"])
        XCTAssertEqual(BrewService.cleanupDryRunArguments(package: "node"), ["cleanup", "--dry-run", "--", "node"])
        XCTAssertEqual(BrewService.autoremoveDryRunArguments(), ["autoremove", "--dry-run"])
        XCTAssertEqual(CleanupActionText.command(for: .cleanup("node")), "brew cleanup -- node")
    }

    func testDryRunsUseTheQueryEnvironment() async throws {
        let runner = QueryRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let service = makeService(runner)
        _ = try await service.cleanupDryRun(package: "node")
        _ = try await service.autoremoveDryRun()
        _ = try await service.cleanupPackage(name: "node")
        let requests = runner.requests
        XCTAssertEqual(requests.count, 3)
        guard requests.count == 3 else { return }
        XCTAssertEqual(requests.map(\.arguments), [
            ["cleanup", "--dry-run", "--", "node"], ["autoremove", "--dry-run"], ["cleanup", "--", "node"]
        ])
        for request in requests.prefix(2) {
            XCTAssertEqual(request.environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
            XCTAssertEqual(request.environment["HOMEBREW_NO_ANALYTICS"], "1")
        }
        XCTAssertEqual(requests[2].environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
    }

    func testHomebrewNames() {
        XCTAssertTrue(CleanupHomebrewNames.isValid("python@3.15"))
        XCTAssertTrue(CleanupHomebrewNames.isValid("user/tap/libbar"))
        XCTAssertTrue(CleanupHomebrewNames.isValid("gcc-c++"))
        for bad in ["", "-rf", "a/b", "../x", "a b", "a;b", "a/b/c/d", "a//b", "-a/b/c", "a/./c", "é"] {
            XCTAssertFalse(CleanupHomebrewNames.isValid(bad), bad)
        }
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
