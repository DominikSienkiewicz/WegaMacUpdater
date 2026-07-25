import Foundation
import Testing

@Suite("Bundle identity snapshot preservation")
struct BundleIdentitySnapshotPreservationTests {
    @Test func bundleIdentifierMismatchRestoresFromAWorkingCopy() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent(
                "Sources/MacUpdater/CaskRollbackGuard.swift"
            ),
            encoding: .utf8
        )
        let mismatchStart = try #require(source.range(
            of: "guard expectedBundleIdentifier == installedBundleIdentifier else {"
        ))
        let mismatchEnd = try #require(source.range(
            of: "let healthy = await Task.detached",
            range: mismatchStart.upperBound..<source.endIndex
        ))
        let mismatchBody = source[mismatchStart.lowerBound..<mismatchEnd.lowerBound]

        #expect(mismatchBody.contains("preservingSnapshot: true"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
