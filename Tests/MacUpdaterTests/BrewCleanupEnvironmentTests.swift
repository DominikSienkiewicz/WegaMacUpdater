import Foundation
import XCTest
@testable import MacUpdaterCore

final class BrewCleanupEnvironmentTests: XCTestCase {
    func testEveryBrewMutationKeepsCleanupDisabledInTheActualRequest() async throws {
        HomebrewEnvironment.touchIDStateOverride = .enabled
        defer { HomebrewEnvironment.touchIDStateOverride = nil }
        let runner = CleanupRequestRecorder()
        let service = BrewService(
            locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]), runner: runner
        )
        _ = try await service.upgradeCask(token: "example")
        _ = try await service.upgradeFormulae()
        _ = try await service.installCask(token: "example")
        for arguments in [BrewService.adoptCaskArguments(token: "example"),
                          BrewService.reinstallCaskArguments(token: "example")] {
            for try await _ in try service.events(arguments: arguments) {}
        }
        XCTAssertEqual(runner.requests.count, 5)
        for request in runner.requests {
            XCTAssertEqual(request.environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
            XCTAssertNil(request.environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"])
            XCTAssertFalse(request.inheritParentEnvironment)
        }
        XCTAssertNil(HomebrewEnvironment.environment["HOMEBREW_NO_INSTALL_CLEANUP"],
                     "The shared MAS authorization environment must not carry Brew policy.")
    }

    func testCleanupPolicyIsAnExplicitOverrideNeverInherited() {
        let key = "HOMEBREW_NO_INSTALL_CLEANUP"
        XCTAssertNil(AuthorizationEnvironment.sanitized(inherited: [key: "0"])[key])
        XCTAssertEqual(AuthorizationEnvironment.sanitized(inherited: [key: "0"], overrides: [key: "1"])[key], "1")
        XCTAssertNil(AuthorizationEnvironment.sanitized(inherited: [:], overrides: ["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1"])["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"])
    }
}

private final class CleanupRequestRecorder: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProcessRequest] = []
    var requests: [ProcessRequest] { lock.withLock { storage } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { storage.append(request) }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        lock.withLock { storage.append(request) }
        return AsyncThrowingStream { $0.finish() }
    }
}
