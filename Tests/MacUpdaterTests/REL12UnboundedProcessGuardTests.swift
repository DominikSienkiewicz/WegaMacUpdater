import Foundation
import Testing
@testable import MacUpdaterCore

/// REL-12 — the limit has to be unavoidable, not merely the default.
///
/// The card's guard already refuses `timeout: nil` and `idleTimeout: nil` anywhere in
/// `Sources/`, and `ProcessRequest` defaults to a bounded policy, so asking for an unbounded
/// wait through `ProcessRunner` takes a deliberate act. That closed the front door and left the
/// back one open: a `Process()` constructed directly, waited on with `waitUntilExit()`, never
/// touches `ProcessRequest` at all and so has no deadline, no inactivity limit, and no
/// SIGTERM → grace → SIGKILL escalation.
///
/// One had survived exactly there — `NpmLocator.resolveFromLoginShell()`, running
/// `$SHELL -lc "command -v npm"` on a raw `Process` and blocking the calling thread until the
/// login shell decided to return. A shell that hangs on a slow network mount in someone's
/// `.zprofile` hung the npm locator with it, and through it every npm operation in the scan.
///
/// So the guard is widened to the shape rather than the spelling: `ProcessRunner` is the one
/// place allowed to wait on a child.
///
/// # Scope
///
/// `MacUpdaterCore` and `MacUpdater` only — the modules where `ProcessRunner` is reachable.
/// `WegaHelperKit`, `WegaSudoShim` and `WegaPrivilegedHelper` sit *below* Core and cannot
/// import it, so the rule is one they have no way to honour; a guard that flagged them would
/// be demanding a fix nobody can make, and would be suppressed rather than obeyed.
///
/// That is a scope decision, not an all-clear. `WegaHelperKit/CodeSignatureVerifier` waits on
/// `codesign`, `spctl`, `pkgutil` and `hdiutil` this way, and a `hdiutil attach` that hangs on
/// a damaged disk image blocks a self-update with no deadline at all — the same failure REL-12
/// is about, one module over. Closing it means giving `WegaHelperKit` a bounded runner of its
/// own, which is more than this card asked for.
@Suite("REL-12 — no process is waited on outside ProcessRunner")
struct REL12UnboundedProcessGuardTests {

    /// Red before the fix: `NpmGlobalChecker.swift` constructed a `Process` and called
    /// `waitUntilExit()` on it, so the npm locator had no limit of any kind.
    @Test func nothingOutsideProcessRunnerWaitsOnAChild() throws {
        var offenders: [String] = []

        for url in try swiftSources(in: ["MacUpdaterCore", "MacUpdater"]) {
            // `ProcessRunner` owns the bounded wait — it is the implementation this guard
            // exists to funnel everything else into.
            guard url.lastPathComponent != "ProcessRunner.swift" else { continue }
            let text = executableSource(try String(contentsOf: url, encoding: .utf8))
            guard text.contains("waitUntilExit()") else { continue }
            offenders.append(url.lastPathComponent)
        }

        #expect(offenders.isEmpty,
                """
                REL-12: \(offenders.joined(separator: ", ")) waits on a child process directly. \
                A raw Process() never sees ProcessRequest, so it has no deadline, no inactivity \
                limit and no SIGTERM → grace → SIGKILL escalation. Route it through \
                ProcessRunning with an explicit ProcessTimeoutPolicy.
                """)
    }

    /// The companion rule: a request names **both** limits or neither.
    ///
    /// `ProcessRequest` has two ways to be explicit — a `timeouts:` policy, or a `timeout:` +
    /// `idleTimeout:` pair — and both are fine. Naming only one is the bug: the missing half
    /// silently inherits the default `.query`, so `timeout: 5` in the diagnostics export was
    /// paired with a 180 s inactivity limit the 5 s deadline could never reach, and
    /// `RunningProcessService` gave `pgrep` and `killall` the ten minutes sized for a `brew
    /// info` over a slow mirror.
    ///
    /// Red before the fix: five requests named one limit or none.
    @Test func everyRequestNamesBothLimitsOrAPolicy() throws {
        var offenders: [String] = []

        for url in try swiftSources(in: ["MacUpdaterCore", "MacUpdater"]) {
            let text = executableSource(try String(contentsOf: url, encoding: .utf8))
            for request in text.components(separatedBy: "ProcessRequest(").dropFirst() {
                let head = String(request.prefix(400))
                // The initializers that *declare* the parameters, not calls to them.
                guard !head.contains("executableURL: URL,") else { continue }
                if head.contains("timeouts:") { continue }
                if head.contains("timeout:") && head.contains("idleTimeout:") { continue }
                offenders.append("\(url.lastPathComponent): \(head.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        #expect(offenders.isEmpty,
                """
                REL-12: these requests leave one limit to the default — \
                \(offenders.joined(separator: " | ")). Name a `timeouts:` policy, or both \
                `timeout:` and `idleTimeout:`; half a pair is how an unreachable inactivity \
                limit gets written by accident.
                """)
    }

    // MARK: Helpers

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftSources(in modules: [String]) throws -> [URL] {
        var urls: [URL] = []
        for module in modules {
            let enumerator = FileManager.default.enumerator(
                at: packageRoot().appendingPathComponent("Sources/\(module)"),
                includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "swift" { urls.append(url) }
            }
        }
        return urls
    }

    /// Comments describe; only code runs. Stripping them first stops a doc comment that
    /// *mentions* `waitUntilExit()` — like the ones explaining this rule — from tripping it.
    private func executableSource(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
