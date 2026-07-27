import Foundation
import Testing

/// P1 — every UI path that replaces an existing `.app` must use the same hard
/// resource, publisher, snapshot, rollback and concurrency boundary as an upgrade.
@Suite("Side-path cask replacement safety")
struct SidePathReplacementSafetyTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func section(_ source: String, from start: String, to end: String) throws -> Substring {
        let startRange = try #require(source.range(of: start))
        let tail = source[startRange.lowerBound...]
        let endRange = try #require(tail.range(of: end))
        return tail[..<endRange.lowerBound]
    }

    @Test func manualInstallCannotBypassTheProtectedReplacementFlow() throws {
        let text = try source("Sources/MacUpdater/ScanStore+Actions.swift")
        let body = try section(
            text,
            from: "func installManual(token: String) async",
            to: "private func reportManualReplacementVerification("
        )

        let mutex = try #require(body.range(of: "UpgradeMutex.shared.acquire()"))
        let preparation = try #require(body.range(of: "CaskReplacementSafety.prepare("))
        let mutation = try #require(body.range(of: "model.brewService.events(arguments: installArgs)"))
        let verification = try #require(body.range(of: "CaskReplacementSafety.verify("))

        #expect(mutex.lowerBound < preparation.lowerBound)
        #expect(preparation.lowerBound < mutation.lowerBound)
        #expect(mutation.lowerBound < verification.lowerBound)
    }

    @Test func migrationCannotBypassTheProtectedReplacementFlow() throws {
        let text = try source("Sources/MacUpdater/MigrationView.swift")
        let body = try section(
            text,
            from: "private func performMigration(_ app: ApplicationInfo, token: String) async",
            to: "private func isProcessRunning("
        )

        let mutex = try #require(body.range(of: "UpgradeMutex.shared.acquire()"))
        let preparation = try #require(body.range(of: "CaskReplacementSafety.prepare("))
        let mutation = try #require(body.range(of: "model.brewService.events(arguments:"))
        let verification = try #require(body.range(of: "CaskReplacementSafety.verify("))

        #expect(mutex.lowerBound < preparation.lowerBound)
        #expect(preparation.lowerBound < mutation.lowerBound)
        #expect(mutation.lowerBound < verification.lowerBound)
        #expect(!body.contains("recordPublisher(for:"),
                "P1: a post-install read must not establish trust after the old app was overwritten")
    }

    @Test func sharedPreparationRunsTheHardGateBeforeThePublisherSnapshot() throws {
        let text = try source("Sources/MacUpdater/CaskReplacementSafety.swift")
        let probe = try #require(text.range(of: "DownloadResourcePreflight.probe("))
        let gate = try #require(text.range(of: "DownloadResourcePreflight.decision("))
        let allow = try #require(text.range(of: "guard case .allow = resourceDecision else"))
        let oldPublisher = try #require(text.range(of: "CodeSignatureVerifier.teamID(ofAppAt: appURL)"))
        let publisherGate = try #require(text.range(of: "TeamIDLedger.classifyCask("))
        let snapshot = try #require(text.range(of: "CaskRollbackGuard.snapshot("))

        #expect(probe.lowerBound < gate.lowerBound)
        #expect(gate.lowerBound < allow.lowerBound)
        #expect(allow.lowerBound < oldPublisher.lowerBound)
        #expect(oldPublisher.lowerBound < publisherGate.lowerBound)
        #expect(publisherGate.lowerBound < snapshot.lowerBound)
        #expect(text.contains("CaskRollbackGuard.verify("),
                "P1: the post-install canary must verify the publisher and roll back a rejected replacement")
    }
}
