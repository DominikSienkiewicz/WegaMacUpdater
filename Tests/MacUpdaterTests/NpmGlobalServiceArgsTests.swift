import XCTest
@testable import MacUpdaterCore

final class NpmGlobalServiceArgsTests: XCTestCase {
    // SEC-10: a `--` terminator must precede the package name so a token can never
    // be reinterpreted as an npm flag.
    func testUninstallArgumentsForScopedPackagePreservesScope() {
        XCTAssertEqual(
            NpmGlobalService.uninstallArguments(for: "@openai/codex"),
            ["uninstall", "-g", "--", "@openai/codex"]
        )
    }

    func testUninstallArgumentsForUnscopedPackage() {
        XCTAssertEqual(
            NpmGlobalService.uninstallArguments(for: "pnpm"),
            ["uninstall", "-g", "--", "pnpm"]
        )
    }
}
