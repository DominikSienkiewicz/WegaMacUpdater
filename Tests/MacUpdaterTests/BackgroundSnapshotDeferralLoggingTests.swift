import Foundation
import Testing

@Suite("Background snapshot deferral logging")
struct BackgroundSnapshotDeferralLoggingTests {
    private func backgroundUpdaterSource(file: String = #filePath) throws -> String {
        let packageRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MacUpdater/BackgroundUpdater.swift"),
            encoding: .utf8
        )
    }

    @Test func partialSnapshotFailureLogsEachDeferredTokenAndContinuesWithBackedTokens() throws {
        let source = try backgroundUpdaterSource()
        let backedTokens = try #require(source.range(
            of: "let tokens = BackgroundUpdateSafety.snapshotBackedTokens(lockedTokens, snapshots: snapshots)"
        ))
        let deferredLoop = try #require(source.range(
            of: "for token in lockedTokens where snapshots[token] == nil"
        ))
        let perTokenReason = try #require(source.range(
            of: "\\(token): aktualizacja w tle odroczona — nie udało się utworzyć wymaganego snapshotu."
        ))
        let emptyBackedGuard = try #require(source.range(of: "guard !tokens.isEmpty else"))
        let backedTokensProceed = try #require(source.range(
            of: "Aktualizacja w tle: \\(tokens.joined(separator: \", \"))"
        ))
        let perTokenLogging = source[deferredLoop.lowerBound ..< perTokenReason.upperBound]

        #expect(backedTokens.lowerBound < deferredLoop.lowerBound)
        #expect(perTokenLogging.contains("WegaLog.error("))
        #expect(deferredLoop.lowerBound < perTokenReason.lowerBound)
        #expect(perTokenReason.lowerBound < emptyBackedGuard.lowerBound)
        #expect(emptyBackedGuard.lowerBound < backedTokensProceed.lowerBound)
    }
}
