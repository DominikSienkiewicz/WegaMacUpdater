import Testing
import Foundation
@testable import MacUpdaterCore

/// REL-06 — the contract `AppDelegate.applicationShouldTerminate` and the menu-bar quit
/// are wired to (`TerminationDuringMutationTests` owns that wiring).
@Suite("MutationGuard")
@MainActor
struct MutationGuardTests {

    /// A guard whose activity assertions are recorded instead of taken out on the process.
    private final class ActivityLog {
        var begun: [(options: ProcessInfo.ActivityOptions, reason: String)] = []
        var ended = 0
    }

    private func makeGuard() -> (MutationGuard, ActivityLog) {
        let log = ActivityLog()
        let sut = MutationGuard(
            beginActivity: { options, reason in
                log.begun.append((options, reason))
                return NSString(string: reason)
            },
            endActivity: { _ in log.ended += 1 }
        )
        return (sut, log)
    }

    @Test func anIdleAppQuitsImmediately() {
        let (sut, _) = makeGuard()
        #expect(sut.isMutating == false)
        #expect(sut.terminationDecision() == .now)
    }

    @Test func anOpenTicketDefersTheQuit() {
        let (sut, _) = makeGuard()
        let ticket = sut.begin("aktualizacja Ghostty")

        #expect(sut.isMutating)
        #expect(sut.terminationDecision() == .waitForMutation)
        #expect(sut.runningLabels == ["aktualizacja Ghostty"])

        sut.end(ticket)
        #expect(sut.terminationDecision() == .now)
        #expect(sut.runningLabels.isEmpty)
    }

    /// Overlapping mutations (a migration while a background round runs) must not let the
    /// first one to finish declare the app idle.
    @Test func concurrentTicketsAreCountedIndependently() {
        let (sut, _) = makeGuard()
        let first = sut.begin("migracja slack")
        let second = sut.begin("usuwanie duplikatu npm:eslint")

        sut.end(first)
        #expect(sut.terminationDecision() == .waitForMutation)
        #expect(sut.runningLabels == ["usuwanie duplikatu npm:eslint"])

        sut.end(second)
        #expect(sut.terminationDecision() == .now)
        // Ending a ticket twice must not reopen the window or unbalance the assertion.
        sut.end(second)
        #expect(sut.terminationDecision() == .now)
    }

    /// `UpgradeMutex` shape: the guard cannot be told when the mutation starts, only asked.
    @Test func aProbeDecidesTheQuitWithoutOwningTheMutation() {
        let (sut, _) = makeGuard()
        let busy = Flag()
        sut.addProbe("aktualizacja Homebrew") { busy.isSet }

        #expect(sut.terminationDecision() == .now)

        busy.isSet = true
        #expect(sut.terminationDecision() == .waitForMutation)
        #expect(sut.runningLabels == ["aktualizacja Homebrew"])
    }

    @Test func aTicketHoldsASuddenTerminationAssertionForItsWholeLife() {
        let (sut, log) = makeGuard()
        #expect(log.begun.isEmpty)

        let ticket = sut.begin("aktualizacja Ghostty")
        #expect(log.begun.count == 1)
        #expect(log.begun.first?.options.contains(.suddenTerminationDisabled) == true)
        #expect(sut.heldActivityCount == 1)

        sut.end(ticket)
        #expect(log.ended == 1)
        #expect(sut.heldActivityCount == 0)
    }

    /// A probe cannot announce its start, so the window it opens is the whole session: the
    /// assertion has to be in place before the mutation, or the log-out kill beats it.
    @Test func aProbePinsTheAssertionForAsLongAsItIsRegistered() {
        let (sut, log) = makeGuard()
        sut.addProbe("aktualizacja Homebrew") { false }

        #expect(sut.heldActivityCount == 1)
        #expect(log.begun.count == 1)

        // A ticket opening and closing on top of it must not drop the probe's assertion.
        let ticket = sut.begin("migracja slack")
        sut.end(ticket)
        #expect(log.begun.count == 1)
        #expect(log.ended == 0)
        #expect(sut.heldActivityCount == 1)
    }

    @MainActor
    private final class Flag { var isSet = false }

    @Test func waitingReturnsOnlyAfterTheLastMutationEnds() async {
        let (sut, _) = makeGuard()
        let done = Flag()
        let ticket = sut.begin("aktualizacja Ghostty")

        let waiter = Task { @MainActor in
            await sut.waitUntilIdle(pollInterval: .milliseconds(5))
            done.isSet = true
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(done.isSet == false, "REL-06: the quit must not proceed while a mutation is in flight")

        sut.end(ticket)
        await waiter.value
        #expect(done.isSet)
    }
}
