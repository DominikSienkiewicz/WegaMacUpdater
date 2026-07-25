import Testing
import Foundation
@testable import MacUpdaterCore

/// REL-04 — an update runs the commands it showed, and nothing else.
///
/// The dry-run panel renders `UpdatePlanner.commands(for:)`, "the same call the upgrade
/// itself executes" (README). It was not the whole truth: `runUpdate` finished every run
/// with a global `brew cleanup` — after an npm-only or App-Store-only update, and after a
/// *failed* one too. A mutation the preview never mentioned, on a scope the plan never
/// mentioned, at the one moment the previous versions in Homebrew's cache are what a
/// recovery would need.
@Suite("UpdatePlanFidelity")
struct UpdatePlanFidelityTests {

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent("Sources/\(path)"), encoding: .utf8)
    }

    /// The regression itself. The window's upgrade path lives behind a live `BrewService`
    /// that a unit test cannot stand in for, so — as `UpdateResultHonestyTests` does for
    /// REL-02 — the wiring is asserted at source level.
    @Test func theUpgradeRunsNoGlobalCleanup() throws {
        let text = try source("MacUpdater/ScanStore.swift")
        #expect(!text.contains("brewService.cleanup()"),
                "REL-04: `brew cleanup` is a mutation the plan preview never showed — it must not run as part of an update")
    }

    /// And it is gone rather than merely unreferenced: an unused `cleanup()` on the service
    /// is an invitation to wire it back in somewhere the preview again cannot see it.
    @Test func theServiceNoLongerOffersAnUnexplainedCleanup() throws {
        #expect(!(try source("MacUpdaterCore/BrewService.swift").contains("func cleanup(")),
                "REL-04: no caller is left for `BrewService.cleanup()`; reintroduce it only behind an explicit, previewed action")
    }

    /// Nothing brew-related may be executed for a plan that contains no Homebrew item —
    /// the property the hidden cleanup broke for every npm-only and App-Store-only run.
    @Test func anNpmAndMasOnlyPlanInvokesNoBrewCommand() {
        let plan = UpdatePlan(formulaNames: [], caskNames: [], npmNames: ["typescript"],
                              includesMas: true, count: 2)

        let executables = UpdatePlanner.commands(for: plan).map(\.executable)

        #expect(!executables.contains("brew"), "REL-04: an npm/MAS update touches no Homebrew state")
        #expect(executables == ["npm", "mas"])
    }
}
