import Testing
import Foundation
@testable import MacUpdaterCore

/// The upgrade pool runs on the main actor: every task in it spends its life awaiting a
/// subprocess, and an `await` releases the actor, so the work overlaps while the state it
/// touches stays on one actor and needs no lock.
@Suite("BoundedConcurrencyOnMainActor")
struct BoundedConcurrencyMainActorTests {

    /// Counts how many jobs were in flight at once. Main-actor isolated, so the counter needs
    /// no synchronisation of its own — which is the property under test.
    @MainActor
    final class Meter {
        var inFlight = 0
        var peak = 0
        func enter() { inFlight += 1; peak = max(peak, inFlight) }
        func leave() { inFlight -= 1 }
    }

    @MainActor
    @Test func neverMoreThanTheLimitRunAtOnce() async {
        let meter = Meter()
        let work: [@MainActor @Sendable () async -> Int] = (0..<9).map { index in
            {
                meter.enter()
                try? await Task.sleep(for: .milliseconds(20))
                meter.leave()
                return index
            }
        }

        let results = await runBoundedOnMainActor(limit: 3, work)

        #expect(meter.peak <= 3)
        #expect(results.sorted() == Array(0..<9))
    }

    /// The jobs must genuinely overlap. Run sequentially, nine 20 ms sleeps take about
    /// 180 ms; three at a time they take about 60 ms. The bound is loose on purpose — the
    /// claim under test is "more than one at a time", not a timing figure.
    @MainActor
    @Test func theJobsActuallyOverlap() async {
        let meter = Meter()
        let work: [@MainActor @Sendable () async -> Int] = (0..<9).map { index in
            {
                meter.enter()
                try? await Task.sleep(for: .milliseconds(20))
                meter.leave()
                return index
            }
        }

        _ = await runBoundedOnMainActor(limit: 3, work)

        #expect(meter.peak > 1)
    }

    /// A cap larger than the work list must not stall waiting for tasks that do not exist.
    @MainActor
    @Test func aLimitAboveTheWorkCountStillCompletes() async {
        let work: [@MainActor @Sendable () async -> Int] = [{ 1 }, { 2 }]
        #expect(await runBoundedOnMainActor(limit: 10, work).sorted() == [1, 2])
    }

    @MainActor
    @Test func anEmptyWorkListReturnsNothing() async {
        let work: [@MainActor @Sendable () async -> Int] = []
        #expect(await runBoundedOnMainActor(limit: 3, work).isEmpty)
    }
}
