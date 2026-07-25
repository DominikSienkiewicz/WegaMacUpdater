import Testing
import Foundation

/// REL-02 — the six paths that ended in a false "success", pinned where they live.
///
/// `UpdateRunOutcomeTests` owns the *contract* (a failed phase is not a success).
/// This suite owns the *wiring*: the contract only protects the user if `ScanStore`,
/// `BackgroundUpdater` and `MenuBarAgent` actually route their result through it. Those
/// three live in the app target, behind `BrewService`/`MasService`/`ManualUpdateScanner`
/// values that a unit test cannot stand in for (the scan shells out and hits the network),
/// so the wiring is asserted where it is checkable — the same source-level guard the
/// SEC-01 regression uses for the migration screen.
@Suite("UpdateResultHonesty")
struct UpdateResultHonestyTests {

    private func packageRoot(file: String = #filePath) -> URL {
        // <root>/Tests/MacUpdaterTests/<thisFile>.swift → up 3 = <root>
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/\(name)"),
                   encoding: .utf8)
    }

    /// The text of the `for`/`switch` block introduced by `header`, up to the line that
    /// closes it at the same indentation — enough to assert what a branch does with its case.
    private func block(after header: String, in text: String) -> String {
        guard let start = text.range(of: header) else { return "" }
        let indent = String(text[text.lineRange(for: start).lowerBound...]
            .prefix { $0 == " " })
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\n\(indent)}") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    /// Path 1: the `mas upgrade` error only ever reached `brewLog`, so the run had no
    /// outcome to be unhappy about and the banner announced "Wszystko gotowe".
    @Test func masFailureBecomesAnOutcome() throws {
        let text = try source("ScanStore.swift")
        #expect(text.contains("run.record(masItems:"),
                "REL-02: a failed `mas upgrade` must produce an outcome, not just a log line")
        #expect(text.contains("masFailure = error.localizedDescription"),
                "REL-02: the thrown mas error must be carried into the run")
    }

    /// Paths 2–3: the cask result was summarized before the canary ran, `postCaskUpgrade`
    /// returned nothing, and the summary only ever saw `BrewUpgradeOutcome`.
    @Test func canaryVerdictsReachTheSummary() throws {
        let text = try source("ScanStore.swift")
        #expect(text.contains("postCaskUpgrade(_ tokens: [String], snapshots: [String: URL]) async -> [String: CaskValidationVerdict]"),
                "REL-02: the canary/rollback verdicts must be returned, not only narrated")
        #expect(text.contains("run.applyValidation(await postCaskUpgrade("),
                "REL-02: the verdicts must be folded into the run before it is summarized")
        #expect(!text.contains("UpdatePlanner.summarize("),
                "REL-02: the banner must not be decided from BrewUpgradeOutcome alone")
    }

    /// Path 4: `.rollbackFailed` — "the one that must never be silent" — was a line in a
    /// collapsible log underneath a green banner.
    @Test func failedRollbackRaisesAStickyBanner() throws {
        let text = try source("ScanStore.swift")
        let branch = block(after: "for outcome in summary.rollbackFailures {", in: text)
        #expect(branch.contains("showStickyBanner("),
                "REL-02: a failed rollback is a red sticky banner, not a log entry")
        #expect(branch.contains("variant: .danger"))
    }

    /// The last phase: the post-upgrade rescan has to agree before anything is announced.
    @Test func theRescanIsPartOfTheResult() throws {
        #expect(try source("ScanStore.swift").contains("run.applyRescan("),
                "REL-02: the post-upgrade rescan must confirm the run")
        #expect(try source("BackgroundUpdater.swift").contains("run.applyRescan("),
                "REL-02: the unattended path needs the same confirmation")
    }

    /// Path 5: in the background, `.publisherChanged` / `.rollbackFailed` were logged and
    /// nothing else — when one of them was the round's only result, no notification went out.
    @Test func backgroundNotificationCoversEveryOutcome() throws {
        let text = try source("BackgroundUpdater.swift")
        #expect(text.contains("private func notify(summary: UpdateRunSummary)"),
                "REL-02: the notification must be derived from the whole run")
        #expect(text.contains("summary.publisherChanges"), "REL-02: notify() needs a publisherChanged variant")
        #expect(text.contains("summary.rollbackFailures"), "REL-02: notify() needs a rollbackFailed variant")
        #expect(!text.contains("notify(upgraded:"),
                "REL-02: a notification built from the successes alone cannot report the failures")
    }

    /// Path 6: the badge used the refreshed scan while the notification still described the
    /// list from before the background upgrade, and "is this new?" compared update *counts*.
    @Test func theAgentKeepsOneResultAndDedupesByIdentity() throws {
        let text = try source("MenuBarAgent.swift")
        #expect(!text.contains("lastNotifiedCount"),
                "REL-02: the notification watermark must be an identity, not a count")
        #expect(text.contains("UpdateFingerprint.of(result: current, policies: policies)"),
                "REL-02: dedupe on the fingerprint of the *current* result")
        #expect(text.contains("postNotification(count: current.total)"),
                "REL-02: the notification must describe the same result as the badge")
    }
}
