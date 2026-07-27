import Testing
@testable import MacUpdaterCore

/// REL-12 — the rule the foreground upgrade's "Anuluj" obeys: an in-flight package is
/// never interrupted (killing `brew` mid-cask is how a half-replaced app bundle happens),
/// so the stop request takes effect at the next package boundary and the untouched
/// remainder is recorded rather than silently dropped.
@Suite("REL-12 update interruption")
struct UpdateInterruptionTests {

    @Test func anUntouchedRunNeverStops() {
        var interruption = UpdateInterruption()

        #expect(!interruption.isRequested)
        let stopped = interruption.shouldStop(before: ["cask:figma", "npm:eslint"])
        #expect(!stopped)
        #expect(interruption.skippedKeys.isEmpty)
        #expect(!interruption.didSkipWork)
    }

    @Test func aRequestedStopSkipsEveryRemainingPackage() {
        var interruption = UpdateInterruption()
        interruption.request()

        #expect(interruption.isRequested)
        let stopped = interruption.shouldStop(before: ["cask:figma", "cask:slack"])
        #expect(stopped)
        #expect(interruption.skippedKeys == ["cask:figma", "cask:slack"])
        #expect(interruption.didSkipWork)
    }

    /// The run walks several boundaries (formulae → casks → each npm package → the App
    /// Store batch); everything left standing at each of them belongs to the same report.
    @Test func skippedPackagesAccumulateAcrossBoundaries() {
        var interruption = UpdateInterruption()
        interruption.request()

        _ = interruption.shouldStop(before: ["npm:eslint"])
        _ = interruption.shouldStop(before: ["mas:497799835", "npm:eslint"])

        #expect(interruption.skippedKeys == ["npm:eslint", "mas:497799835"])
    }

    /// Pressing "Anuluj" while the last package is already running stops nothing: the run
    /// finished everything it planned, so it must still be reported as a normal run.
    @Test func stoppingWithNothingLeftSkipsNoWork() {
        var interruption = UpdateInterruption()
        interruption.request()

        let stopped = interruption.shouldStop(before: [])
        #expect(stopped)
        #expect(interruption.skippedKeys.isEmpty)
        #expect(!interruption.didSkipWork)
    }
}

/// The projection of a plan onto "what is left at this boundary". The run executes
/// formulae → cask batch → npm packages one by one → App Store batch, and each boundary
/// has to name exactly the work that follows it.
@Suite("REL-12 upgrade boundary keys")
struct UpgradeBoundaryKeysTests {
    private func item(_ key: String, _ name: String, _ kind: OutdatedItem.Kind) -> OutdatedItem {
        OutdatedItem(key: key, name: name, from: "1.0", to: "2.0", kind: kind)
    }

    private var planned: [OutdatedItem] {
        [
            item("formula:jq", "jq", .formula),
            item("cask:figma", "figma", .cask),
            item("npm:eslint", "eslint", .npm),
            item("npm:typescript", "typescript", .npm),
            item("mas:497799835", "Xcode", .appStore)
        ]
    }

    @Test func everythingAfterTheFormulaBatchIsTheRestOfTheRun() {
        let boundaries = UpgradeBoundaryKeys(planned: planned, npmNames: ["eslint", "typescript"])

        #expect(boundaries.afterFormulae == ["cask:figma", "npm:eslint", "npm:typescript", "mas:497799835"])
    }

    /// npm keys follow the execution order of `npmNames`, not the order the scan listed
    /// them — otherwise "what is left" after package two could name package one.
    @Test func npmKeysFollowTheOrderTheRunWillInstallThem() {
        let boundaries = UpgradeBoundaryKeys(planned: planned, npmNames: ["typescript", "eslint"])

        #expect(boundaries.npmKeys == ["npm:typescript", "npm:eslint"])
        #expect(boundaries.fromNpmPackage(at: 1) == ["npm:eslint", "mas:497799835"])
        #expect(boundaries.fromNpmPackage(at: 2) == ["mas:497799835"])
    }

    @Test func aPlanWithoutAKindContributesNoKeysForIt() {
        let boundaries = UpgradeBoundaryKeys(
            planned: [item("formula:jq", "jq", .formula)],
            npmNames: []
        )

        #expect(boundaries.afterFormulae.isEmpty)
        #expect(boundaries.masKeys.isEmpty)
    }
}
