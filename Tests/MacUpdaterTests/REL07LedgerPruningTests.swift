import Foundation
import Testing
@testable import MacUpdaterCore

/// REL-07 follow-up — the rolled-back ledger forgets casks that are gone, and only those.
///
/// A mark is what stops a reverted cask reading as current: `brew outdated` goes quiet about it
/// (its Caskroom records the *new* version), so without the mark the reverted build vanishes
/// from every scan until upstream ships something newer. That makes pruning the delicate half —
/// forgetting a mark too eagerly re-creates the exact bug REL-07 was written to fix.
///
/// It leaked in the direction that shows least. `rolledBackRows` skips a token whose app it
/// cannot find, so an uninstalled cask's mark produced no row, raised no error, and stayed in
/// `UserDefaults` for good.
@Suite("REL-07 — the ledger forgets uninstalled casks, and nothing else")
struct REL07LedgerPruningTests {

    // MARK: The decision

    @Test func aMarkForAnUninstalledCaskIsForgotten() {
        let prunable = CaskRollbackLedger.prunableTokens(
            rolledBack: ["figma", "gone"],
            installedCaskTokens: ["figma", "slack"]
        )

        #expect(prunable == ["gone"])
    }

    /// The case that must never prune. `caskInstalledVersions()` falls back to an empty map
    /// when brew is missing or the query failed, and the scan passes that straight through.
    ///
    /// Red before the fix: without the empty-list guard, one failed `brew list` wipes every
    /// mark on the machine — turning a transient failure into silently reverted apps that read
    /// as current from then on.
    @Test func anEmptyInstalledListForgetsNothing() {
        let prunable = CaskRollbackLedger.prunableTokens(
            rolledBack: ["figma", "slack"],
            installedCaskTokens: []
        )

        #expect(prunable.isEmpty,
                """
                REL-07: an empty installed list means brew could not answer, not that every \
                cask was uninstalled. Pruning on it discards the marks that make reverted \
                builds visible.
                """)
    }

    @Test func aMarkForAStillInstalledCaskSurvives() {
        #expect(CaskRollbackLedger.prunableTokens(
            rolledBack: ["figma"],
            installedCaskTokens: ["figma"]
        ).isEmpty)
    }

    // MARK: Through the store

    @Test func pruningRemovesOnlyTheForgottenTokens() throws {
        let suite = "wega.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = CaskRollbackLedger(defaults: defaults)

        ledger.recordRollback(token: "figma", reason: .checkFailed)
        ledger.recordRollback(token: "gone", reason: .publisherChanged)

        ledger.prune(installedCaskTokens: ["figma"])

        #expect(ledger.isRolledBack(token: "figma"))
        #expect(!ledger.isRolledBack(token: "gone"))
        #expect(ledger.reason(forToken: "figma") == .checkFailed,
                "REL-07: pruning forgets entries, it does not rewrite the ones it keeps")
    }

    @Test func pruningOnAFailedBrewQueryLeavesTheLedgerIntact() throws {
        let suite = "wega.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = CaskRollbackLedger(defaults: defaults)

        ledger.recordRollback(token: "figma", reason: .checkFailed)
        ledger.prune(installedCaskTokens: [])

        #expect(ledger.rolledBackTokens() == ["figma"])
    }

    // MARK: The scan actually prunes

    /// A prune nobody calls would pass everything above and clean nothing. Asserted at source
    /// level because driving a real scan needs brew, a filesystem full of apps, and the network.
    ///
    /// Red before the fix: nothing in `Sources/` called `prune`.
    @Test func theScanPrunesFromBrewsOwnInstalledList() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdaterCore/ManualUpdateScanner.swift"),
            encoding: .utf8
        )

        #expect(source.contains("rollbackLedger.prune(installedCaskTokens: Set(brewCaskVersions.keys))"),
                """
                REL-07: the scan must prune from `brewCaskVersions` — brew's own installed list, \
                which stays authoritative for a rolled-back cask because its Caskroom entry \
                survives the rollback. Pruning from the apps a scan happened to see would drop \
                marks whenever a scan was partial.
                """)
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
