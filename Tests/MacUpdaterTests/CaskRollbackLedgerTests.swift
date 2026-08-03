import Foundation
import Testing
import WegaTestSupport
@testable import MacUpdaterCore

/// REL-07 — the persistent "rolled back" state that keeps an auto-reverted cask visible.
///
/// After `CaskRollbackGuard.verify` restores the previous bundle, Homebrew's Caskroom still
/// records the *new* version, so `brew outdated` goes silent and every scan drops the app.
/// This ledger is the durable memory that survives that silence: a token stays marked until a
/// genuinely healthy install clears it, which is what lets the scanner force the row back onto
/// the list. See [[vendor-checker-driver-arch06]] for where the forced row is labelled.
@Suite("REL-07 — CaskRollbackLedger")
struct CaskRollbackLedgerTests {

    private func isolatedLedger() -> (CaskRollbackLedger, () -> Void) {
        let (defaults, teardown) = TestDefaults.isolated("rel07-rollback-ledger")
        return (CaskRollbackLedger(defaults: defaults), teardown)
    }

    @Test func recordsAndReportsARolledBackToken() throws {
        let (ledger, cleanup) = isolatedLedger()
        defer { cleanup() }

        #expect(!ledger.isRolledBack(token: "figma"))
        ledger.recordRollback(token: "figma", reason: .checkFailed)

        #expect(ledger.isRolledBack(token: "figma"))
        #expect(ledger.rolledBackTokens() == ["figma"])
        #expect(ledger.reason(forToken: "figma") == .checkFailed)
    }

    @Test func clearRemovesTheToken() throws {
        let (ledger, cleanup) = isolatedLedger()
        defer { cleanup() }

        ledger.recordRollback(token: "figma", reason: .publisherChanged)
        ledger.clear(token: "figma")

        #expect(!ledger.isRolledBack(token: "figma"))
        #expect(ledger.rolledBackTokens().isEmpty)
        #expect(ledger.reason(forToken: "figma") == nil)
    }

    /// The verdict → ledger action mapping — the bridge from the `verify` decision matrix
    /// (`QA-01i`) into durable state. Only the two *restored* verdicts persist a mark.
    @Test func applyMapsRolledBackVerdictsToAMark() throws {
        let (ledger, cleanup) = isolatedLedger()
        defer { cleanup() }

        ledger.apply(token: "canary", verdict: .rolledBack)
        ledger.apply(token: "publisher", verdict: .publisherChangedAndRolledBack(old: "OLD", new: "NEW"))

        #expect(ledger.reason(forToken: "canary") == .checkFailed)
        #expect(ledger.reason(forToken: "publisher") == .publisherChanged)
    }

    /// A conscious retry that finally lands healthy must erase the mark — otherwise the row
    /// would haunt the list forever (criterion: "user does not see a stale rolled-back app").
    @Test func applyHealthyClearsAPreviouslyRolledBackToken() throws {
        let (ledger, cleanup) = isolatedLedger()
        defer { cleanup() }

        ledger.apply(token: "figma", verdict: .rolledBack)
        #expect(ledger.isRolledBack(token: "figma"))

        ledger.apply(token: "figma", verdict: .healthy)
        #expect(!ledger.isRolledBack(token: "figma"))
    }

    /// A failed *restore* is a different, louder failure (the new bad build is still on disk);
    /// it is surfaced as a critical result in the run summary and must not be quietly folded
    /// into the "rolled back — retry" state, nor may it erase an existing mark.
    @Test func applyRollbackFailedLeavesTheLedgerUntouched() throws {
        let (ledger, cleanup) = isolatedLedger()
        defer { cleanup() }

        ledger.apply(token: "figma", verdict: .rolledBack)
        ledger.apply(token: "figma", verdict: .rollbackFailed)
        #expect(ledger.isRolledBack(token: "figma"),
                "REL-07: a subsequent rollback-failure must not clear the earlier rolled-back mark")

        #expect(!ledger.isRolledBack(token: "fresh"))
        ledger.apply(token: "fresh", verdict: .rollbackFailed)
        #expect(!ledger.isRolledBack(token: "fresh"),
                "REL-07: rollback-failure alone is not the rolled-back-and-restored state this ledger tracks")
    }

    /// The mark has to outlive the process: a relaunch reads the same list before any rescan,
    /// so the ledger is UserDefaults-backed exactly like `TeamIDLedger`.
    @Test func marksPersistAcrossLedgerInstances() throws {
        let (defaults, teardown) = TestDefaults.isolated("rel07-rollback-ledger")
        defer { teardown() }

        CaskRollbackLedger(defaults: defaults).recordRollback(token: "figma", reason: .checkFailed)
        #expect(CaskRollbackLedger(defaults: defaults).isRolledBack(token: "figma"))
    }
}
