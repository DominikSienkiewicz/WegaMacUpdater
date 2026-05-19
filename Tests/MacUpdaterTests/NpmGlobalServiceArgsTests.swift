import XCTest
@testable import MacUpdaterCore

final class NpmGlobalServiceArgsTests: XCTestCase {
    func testUninstallArgumentsForScopedPackagePreservesScope() {
        XCTAssertEqual(
            NpmGlobalService.uninstallArguments(for: "@openai/codex"),
            ["uninstall", "-g", "@openai/codex"]
        )
    }

    func testUninstallArgumentsForUnscopedPackage() {
        XCTAssertEqual(
            NpmGlobalService.uninstallArguments(for: "pnpm"),
            ["uninstall", "-g", "pnpm"]
        )
    }
}
