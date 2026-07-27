import Testing
import Foundation
@testable import MacUpdaterCore

/// ARCH-02 — the two resource bounds a long-lived `ProcessRunner` must hold: captured
/// output rolls instead of growing without bound, and concurrent process launches are
/// capped.
@Suite("ProcessRunner bounds")
struct ProcessRunnerBoundsTests {

    /// Records how many acquisitions overlap at once.
    private actor Meter {
        private(set) var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    /// A process that prints far more than the capture cap must not grow the captured
    /// buffer past that cap: the memory stays bounded while the process still finishes
    /// cleanly. The rolling buffer keeps the most recent bytes, so the final line
    /// survives.
    @Test func largeOutputIsBoundedByTheRollingBuffer() async throws {
        let cap = 4096
        let runner = ProcessRunner(limiter: ProcessLimiter(limit: 4), maxCapturedBytesPerStream: cap)

        // ~282 KB of output — roughly 70× the cap.
        let count = 50_000
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "\(count)"]
        )

        let result = try await runner.run(request)

        #expect(result.exitCode == 0)
        #expect(
            result.stdout.utf8.count <= cap,
            "captured stdout grew to \(result.stdout.utf8.count) bytes, past the \(cap)-byte cap"
        )
        #expect(
            result.stdout.hasSuffix("\(count)\n"),
            "the rolling buffer must retain the most recent output"
        )
    }

    /// The concurrency gate `ProcessRunner` uses to bound process launches never lets more
    /// than `limit` acquisitions run at once, yet still overlaps them.
    @Test func processLimiterNeverExceedsItsLimit() async {
        let limit = 3
        let total = 40
        let limiter = ProcessLimiter(limit: limit)
        let meter = Meter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await limiter.acquire()
                    await meter.enter()
                    try? await Task.sleep(for: .milliseconds(2))
                    await meter.leave()
                    await limiter.release()
                }
            }
        }

        #expect(await meter.peak <= limit)     // the bound is honoured
        #expect(await meter.peak >= 2)         // and work really did overlap
    }

    /// `ProcessRunner` actually routes process launches through its limiter: with a limit
    /// of one, a second run cannot start its process until the first releases the permit.
    @Test func runnerSerializesLaunchesToItsConcurrencyLimit() async throws {
        let runner = ProcessRunner(limiter: ProcessLimiter(limit: 1))
        let clock = ContinuousClock()
        let start = clock.now

        let blocker = Task {
            try? await runner.run(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["0.7"]
                )
            )
        }
        // Let the blocker claim the sole permit and launch its process.
        try await Task.sleep(for: .milliseconds(150))

        _ = try await runner.run(
            ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        )
        let elapsed = clock.now - start
        _ = await blocker.value

        // `/usr/bin/true` returns in ~milliseconds on its own; only the permit held by the
        // 0.7 s sleep can hold its launch back this long.
        #expect(
            elapsed > .milliseconds(450),
            "second run started after \(elapsed), so the concurrency limit was not enforced"
        )
    }
}
