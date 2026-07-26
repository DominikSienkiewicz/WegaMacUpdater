import Testing
import Foundation
import Darwin
@testable import MacUpdaterCore

/// QA-01f — regression coverage for the guarantee fixed in REL-12: cancelling an
/// in-flight `ProcessRunner.run` must kill the spawned process **and every descendant
/// it started**, not merely the immediate child. The scan "Anuluj" button (M2c) relies
/// on this end-to-end contract.
///
/// This test is also the agreed way (§14.5) to settle REL-12's factual discrepancy —
/// "does cancellation actually propagate into `ProcessRunner`?" — in code rather than
/// on paper.
@Suite("QA-01f cancellation kills process and descendants")
struct QA01FCancellationKillsChildrenTests {

    /// The subprocess is `/bin/sh` (the direct child). It backgrounds a long-lived
    /// `/bin/sleep` — a *grandchild* of the updater — and records both PIDs to files so
    /// the test can confirm the whole tree is live before cancelling and fully dead
    /// afterwards.
    ///
    /// Two independent regressions would each keep this red:
    ///   1. `run` ran its work on a `Task.detached`, which never inherits cancellation, so
    ///      the `.cancelled` abort was unreachable and the process ran to completion.
    ///   2. Even once aborted, `process.terminate()` signals only the shell, orphaning the
    ///      backgrounded `sleep`.
    @Test func cancellationKillsProcessAndDescendants() async throws {
        let runner = ProcessRunner()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa01f-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let childPidFile = dir.appendingPathComponent("child.pid")
        let grandPidFile = dir.appendingPathComponent("grand.pid")

        // The shell records its own PID, backgrounds a long `sleep` (the descendant),
        // records the sleep's PID via `$!`, then blocks in `wait`. `sleep 30` far
        // outlives the test, so any death we observe is the cancellation's doing rather
        // than the process exiting on its own.
        let script = """
        echo $$ > '\(childPidFile.path)'
        /bin/sleep 30 &
        echo $! > '\(grandPidFile.path)'
        wait
        """
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            // Belt-and-suspenders: if cancellation ever stops reaching the process, the
            // run fails fast via `.timedOut` instead of hanging the suite on `sleep 30`.
            timeout: 15
        )

        let task = Task { try await runner.run(request) }

        // Never cancel before the whole tree is actually up, or the test proves nothing.
        let discoveredChild = await pollForPid(in: childPidFile)
        let discoveredGrand = await pollForPid(in: grandPidFile)
        let childPid = try #require(discoveredChild)
        let grandPid = try #require(discoveredGrand)
        let childUp = await pollUntil { isAlive(childPid) }
        let grandUp = await pollUntil { isAlive(grandPid) }
        #expect(childUp, "the shell never started")
        #expect(grandUp, "the descendant sleep never started")

        task.cancel()

        // Cancelling an in-flight run surfaces `.cancelled` (the REL-12 / M2c contract),
        // not a normal result and not a timeout.
        await #expect(throws: ProcessRunnerError.cancelled) {
            _ = try await task.value
        }

        // The shell *and* the sleep it spawned must both be gone.
        let childDied = await pollUntil { !isAlive(childPid) }
        let grandDied = await pollUntil { !isAlive(grandPid) }
        #expect(childDied, "the shell (direct child) survived cancellation")
        #expect(grandDied, "the backgrounded sleep (descendant) survived cancellation")
    }

    /// A process exists and is signallable by us exactly when `kill(pid, 0)` succeeds;
    /// once it dies and is reaped, `kill` fails with `ESRCH`.
    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Reads a PID a shell wrote with `echo $$`/`echo $!`; `nil` until the file exists and
    /// holds a fully-written integer.
    private func readPid(_ url: URL) -> pid_t? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Polls up to ~10s for `file` to yield a PID.
    private func pollForPid(in file: URL) async -> pid_t? {
        for _ in 0..<500 {
            if let pid = readPid(file) { return pid }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return readPid(file)
    }

    /// Polls up to ~10s for `condition` to hold.
    private func pollUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
