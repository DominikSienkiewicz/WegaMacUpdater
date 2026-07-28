import Foundation
import Testing
@testable import WegaHelperKit

/// REL-12, one module down — the signature verifier's commands cannot wait forever either.
///
/// `ProcessRunner` bounds everything the update pipeline runs, and its guard refuses an
/// unbounded wait there. `WegaHelperKit` is out of that guard's reach by construction: it is
/// the base module the root daemon links precisely so it does *not* pull in Core, so the
/// dependency points one way and `ProcessRunner` is async besides.
///
/// So `CodeSignatureVerifier` kept waiting on `codesign`, `spctl`, `pkgutil` and `hdiutil` with
/// a bare `waitUntilExit()`. The one that mattered is `hdiutil attach`: a damaged or truncated
/// disk image can leave it wedged, and the self-update mounts its `.dmg` through exactly that
/// call — so the update hung, with no deadline and nothing to cancel.
///
/// These run real children, because the whole property is about a process that does not end on
/// its own; a stand-in that returns when asked would be testing the wrong thing.
@Suite("REL-12 — WegaHelperKit's commands are bounded too")
struct BoundedProcessTests {

    @Test func aCommandThatFinishesReturnsItsOutputAndStatus() throws {
        let result = try BoundedProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf ok; printf oops 1>&2; exit 3"],
            timeouts: ProcessTimeoutPolicy(deadline: 10, idle: 10)
        )

        #expect(result.exitCode == 3)
        #expect(result.standardOutput == "ok")
        #expect(result.standardError == "oops")
    }

    /// The property the type exists for. Red before the fix: `waitUntilExit()` on this child
    /// never returns, so the caller — and the self-update behind it — waits forever.
    @Test func aCommandThatOutlivesItsDeadlineIsStopped() throws {
        let started = Date()

        #expect(throws: BoundedProcess.Failure.timedOut(seconds: 0.3)) {
            try BoundedProcess.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 30"],
                timeouts: ProcessTimeoutPolicy(deadline: 0.3, idle: 0.3)
            )
        }

        #expect(Date().timeIntervalSince(started) < 5,
                "REL-12: the deadline is what ends the wait, not the command")
    }

    /// Polite signal, grace, then the unconditional one — the same escalation `ProcessRunner`
    /// uses. This child traps `TERM` and ignores it, so only the SIGKILL at the end of the
    /// grace period can end it.
    ///
    /// Red before the fix: with no escalation the call returns while the child is still
    /// running, leaving a stray process — and, for `hdiutil`, a half-attached image.
    @Test func aCommandThatIgnoresThepoliteSignalIsKilled() throws {
        let started = Date()

        #expect(throws: BoundedProcess.Failure.self) {
            try BoundedProcess.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; sleep 30"],
                timeouts: ProcessTimeoutPolicy(deadline: 0.3, idle: 0.3)
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.3, "the deadline was actually waited out")
        #expect(elapsed < BoundedProcess.terminationGracePeriod + 5,
                "REL-12: the grace period ends in a kill, not in another wait")
    }

    @Test func anExecutableThatDoesNotExistFailsRatherThanHanging() {
        #expect(throws: BoundedProcess.Failure.self) {
            try BoundedProcess.run(
                URL(fileURLWithPath: "/nonexistent/wega-not-a-tool"),
                arguments: [],
                timeouts: .quick
            )
        }
    }

    // MARK: The verifier actually uses it

    /// Source-level: the four call sites are the reason this type exists, and a bounded runner
    /// nobody calls would pass every test above while changing nothing.
    ///
    /// Red before the fix: `CodeSignatureVerifier` contained four `waitUntilExit()` calls.
    @Test func theSignatureVerifierWaitsOnNothingDirectly() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/WegaHelperKit/CodeSignatureVerifier.swift"),
            encoding: .utf8
        )
        let code = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(!code.contains("waitUntilExit()"),
                """
                REL-12: CodeSignatureVerifier waits on a child directly. hdiutil, spctl, \
                pkgutil and codesign all reach the network or the disk and all can wedge; \
                route them through BoundedProcess.
                """)
        #expect(code.contains("BoundedProcess.run("),
                "REL-12: and the bounded runner is what it waits through instead")
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
