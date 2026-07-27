import Testing
import Foundation
import Darwin
@testable import MacUpdaterCore

/// REL-12 — what "cancelling" and "timing out" have to actually guarantee.
///
/// `QA-01f` already pins the coarse guarantee (a cancelled run kills the child *and* its
/// descendants). These pin the two properties it does not cover:
///
///   * stopping is a **sequence** — SIGTERM, a short grace period, then SIGKILL — so a
///     package manager gets the chance to unwind (release its lock, delete a half-written
///     staging directory) instead of being shot in the head mid-write;
///   * every operation is bounded by **two** limits, a wall-clock deadline *and* an
///     inactivity timeout, so a `brew`/`mas`/`npm` that stops making progress without
///     exiting cannot hold the UI and the upgrade mutex forever.
@Suite("REL-12 process lifetime")
struct REL12ProcessLifetimeTests {

    // MARK: - SIGTERM → grace → SIGKILL

    /// The polite signal must come first, and the process must be given long enough to act
    /// on it. The shell here installs a `TERM` trap that writes a file and exits; the file
    /// exists afterwards only if SIGTERM was delivered *and* the trap had time to run.
    ///
    /// Red before the fix: `terminateProcessTree` fired `terminate()` and `killpg(SIGKILL)`
    /// back to back, so the trap never got to run — the grace period did not exist.
    @Test func cancellationSendsSigtermBeforeSigkillSoTheProcessCanCleanUp() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let readyFile = dir.appendingPathComponent("ready")
        let trapFile = dir.appendingPathComponent("trapped")

        // The trap writes its evidence and exits; `ready` is written only once the trap is
        // installed, so the test never cancels before the window it is measuring is open.
        let script = """
        trap "echo caught > '\(trapFile.path)'; exit 0" TERM
        echo up > '\(readyFile.path)'
        while :; do /bin/sleep 0.2; done
        """
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeouts: .init(deadline: 30, idle: 30)
        )

        let task = Task { try await ProcessRunner().run(request) }
        #expect(await Self.pollUntil { FileManager.default.fileExists(atPath: readyFile.path) },
                "the shell never installed its TERM trap")
        // The evidence must not pre-date the cancellation, or the test proves nothing.
        #expect(!FileManager.default.fileExists(atPath: trapFile.path))

        task.cancel()
        await #expect(throws: ProcessRunnerError.cancelled) {
            _ = try await task.value
        }

        #expect(await Self.pollUntil { FileManager.default.fileExists(atPath: trapFile.path) },
                "the process was killed without a chance to handle SIGTERM")
    }

    /// The grace period may not become an escape hatch: a process that ignores SIGTERM is
    /// still killed once it expires. Guards the other half of the sequence — a grace period
    /// implemented without the escalation would hang the cancel button forever.
    @Test func aProcessThatIgnoresSigtermIsKilledAfterTheGracePeriod() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("child.pid")

        let script = """
        trap "" TERM
        echo $$ > '\(pidFile.path)'
        while :; do /bin/sleep 0.2; done
        """
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeouts: .init(deadline: 60, idle: 60)
        )

        let task = Task { try await ProcessRunner().run(request) }
        let pid = try #require(await Self.pollForPid(in: pidFile))
        #expect(await Self.pollUntil { Self.isAlive(pid) }, "the shell never started")

        task.cancel()
        await #expect(throws: ProcessRunnerError.cancelled) {
            _ = try await task.value
        }

        #expect(await Self.pollUntil { !Self.isAlive(pid) },
                "a SIGTERM-ignoring process survived cancellation")
    }

    // MARK: - Inactivity timeout

    /// A process that is alive but has gone quiet is stopped by its inactivity timeout,
    /// long before its (much longer) wall-clock deadline. This is the limit that a hung
    /// `brew`/`mas` needs: it never exits and never prints, so only silence gives it away.
    @Test func silenceLongerThanTheIdleTimeoutStopsTheProcess() async throws {
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeouts: .init(deadline: 30, idle: 0.5)
        )

        await #expect(throws: ProcessRunnerError.idleTimedOut(seconds: 0.5)) {
            _ = try await ProcessRunner().run(request)
        }
    }

    /// …and a slow-but-talking process is not: every chunk of output rearms the timer, so a
    /// long download that keeps reporting progress runs to completion under an idle timeout
    /// far shorter than its total runtime.
    @Test func steadyOutputKeepsRearmingTheIdleTimeout() async throws {
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 12 ]; do echo tick; /bin/sleep 0.2; i=$((i+1)); done"],
            timeouts: .init(deadline: 30, idle: 1)
        )

        let result = try await ProcessRunner().run(request)
        #expect(result.exitCode == 0)
        #expect(result.stdout.components(separatedBy: "tick").count - 1 == 12)
    }

    // MARK: - Streaming path

    /// The upgrade paths consume `events(for:)`, not `run(_:)`. Cancelling the *consumer*
    /// must reach the subprocess exactly the same way — otherwise "Anuluj" during a
    /// `brew upgrade` would leave brew running with nobody reading its output.
    @Test func cancellingAStreamConsumerKillsTheProcess() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("child.pid")

        let script = """
        echo $$ > '\(pidFile.path)'
        while :; do echo working; /bin/sleep 0.2; done
        """
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeouts: .init(deadline: 60, idle: 60)
        )

        let runner = ProcessRunner()
        let consumer = Task {
            for try await _ in runner.events(for: request) { }
        }

        let pid = try #require(await Self.pollForPid(in: pidFile))
        #expect(await Self.pollUntil { Self.isAlive(pid) }, "the shell never started")

        consumer.cancel()
        _ = try? await consumer.value

        #expect(await Self.pollUntil { !Self.isAlive(pid) },
                "the streamed process outlived its cancelled consumer")
    }

    // MARK: - Helpers

    private static func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rel12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A process exists and is signallable by us exactly when `kill(pid, 0)` succeeds.
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Polls up to ~15s for `condition` to hold — comfortably longer than the grace period
    /// the escalation waits out.
    private static func pollUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<750 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func pollForPid(in file: URL) async -> pid_t? {
        for _ in 0..<750 {
            if let contents = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
