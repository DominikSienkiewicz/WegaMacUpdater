import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Package receipt ownership preserves all claims")
struct PackageReceiptIdentifiersTests {
    private let bundle = URL(fileURLWithPath: "/Fixtures/Example.app")

    @Test func allDistinctClaimsAreReturnedWithoutChangingTheLegacyFirstClaim() async {
        let locator = PackageReceiptLocator(runner: ReceiptIdentifiersRunner(
            output: "pkgid: com.first\n\npkgid: com.second\n\npkgid: com.first\n", exitCode: 0
        ))
        #expect(await locator.packageIdentifiers(forBundleAt: bundle) == ["com.first", "com.second"])
        #expect(await locator.packageIdentifier(forBundleAt: bundle) == "com.first")
    }

    @Test func failedReceiptLookupCannotAssignOwnership() async {
        let locator = PackageReceiptLocator(runner: ReceiptIdentifiersRunner(output: "pkgid: stale.claim\n", exitCode: 1))
        #expect(await locator.packageIdentifiers(forBundleAt: bundle).isEmpty)
    }
}

private struct ReceiptIdentifiersRunner: ProcessRunning {
    let output: String
    let exitCode: Int32

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: output, stderr: "")
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
