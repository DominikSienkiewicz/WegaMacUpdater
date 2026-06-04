import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("BoundedConcurrency")
struct BoundedConcurrencyTests {

    /// Records how many tasks are in flight at once.
    private actor Meter {
        private(set) var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    /// `runBounded` must run work concurrently but never let more than `limit` tasks
    /// run at the same time, and must still return every result.
    @Test func neverExceedsLimitAndReturnsAllResults() async {
        let meter = Meter()
        let limit = 4
        let total = 60

        let work: [@Sendable () async -> Int] = (0..<total).map { index in
            {
                await meter.enter()
                // Hold the slot briefly so overlap is real and the peak is observable.
                try? await Task.sleep(nanoseconds: 2_000_000)
                await meter.leave()
                return index
            }
        }

        let results = await runBounded(limit: limit, work)

        #expect(results.count == total)
        #expect(Set(results) == Set(0..<total))           // nothing dropped or duplicated

        let peak = await meter.peak
        #expect(peak <= limit)                            // the bound is honoured
        #expect(peak >= 2)                                // and work really did overlap
    }

    /// An empty work list completes immediately with no results.
    @Test func emptyWorkReturnsEmpty() async {
        let results = await runBounded(limit: 4, [@Sendable () async -> Int]())
        #expect(results.isEmpty)
    }

    /// A limit larger than the work count still runs everything exactly once.
    @Test func limitLargerThanWorkRunsEverything() async {
        let work: [@Sendable () async -> Int] = (0..<3).map { i in { i } }
        let results = await runBounded(limit: 100, work)
        #expect(Set(results) == Set(0..<3))
    }
}
