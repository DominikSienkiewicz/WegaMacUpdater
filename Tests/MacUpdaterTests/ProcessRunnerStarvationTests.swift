import Testing
import Foundation
@testable import MacUpdaterCore

/// ARCH-02 — long-running external processes must not park cooperative-pool threads.
///
/// The pre-fix `ProcessRunner` waited for a subprocess by blocking a semaphore inside a
/// `Task.detached` body. `Task.detached` still runs on the global cooperative executor
/// (width = core count), so every in-flight `brew`/`npm`/`mas` occupied one pool thread
/// for its whole lifetime. A scan fanning out more processes than the pool is wide
/// exhausted the pool and unrelated async work could not be scheduled — the runtime
/// starvation this card removes.
@Suite("ProcessRunner starvation")
struct ProcessRunnerStarvationTests {

    /// Launch far more long-running processes than the cooperative pool is wide, then
    /// require that a small piece of unrelated async work still makes prompt progress.
    ///
    /// Red on the blocking implementation: all pool threads sit inside the subprocess
    /// wait loops, so the probe's timer resumptions cannot be serviced until a process
    /// exits (seconds away). Green once the wait suspends on a continuation and holds no
    /// thread — the probe runs immediately.
    @Test func manyRunningProcessesDoNotStarveTheAsyncRuntime() async {
        let runner = ProcessRunner()
        let processCount = max(16, ProcessInfo.processInfo.activeProcessorCount * 2)

        let runs = (0..<processCount).map { _ in
            Task {
                try? await runner.run(
                    ProcessRequest(
                        executableURL: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: ["3"],
                        // Safety net so a regression can never hang the suite here.
                        timeout: 30
                    )
                )
            }
        }
        defer { runs.forEach { $0.cancel() } }

        // Unrelated async work: 20 short timer hops, each of which needs the cooperative
        // executor to resume it. Nominally ~100 ms of real work.
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = clock.now - start

        #expect(
            elapsed < .seconds(1),
            "unrelated async work was starved for \(elapsed) while \(processCount) processes ran"
        )

        runs.forEach { $0.cancel() }
        for run in runs { _ = await run.value }
    }
}
