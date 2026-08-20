import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// Adoption lands the version that is already on disk — and that is a success, not a no-op.
///
/// Observed 2026-08-20 on "Przepnij pod Brew": `/Applications/Proton Drive.app` at 3.0.2, cask
/// `proton-drive` at 3.0.2. The log shows brew doing the whole job — `Removing App`, `Moving
/// App`, `was successfully installed!` — and the migration was then reported as
/// `.notUpgraded`: *"brew zakończył się sukcesem, ale na dysku została wersja sprzed migracji
/// — nic nie zainstalowano."* `MigrationStore` bails out on that verdict before
/// `migrated.insert(token)`, so the app stayed listed as a takeover candidate although
/// Homebrew already owned it.
///
/// The arrival gate infers "an artifact arrived" from a changed `CFBundleShortVersionString`.
/// That reading is only valid for `brew upgrade`, where the target version differs by
/// definition and an unchanged one means brew exited 0 on a stale Caskroom record. Adoption
/// runs `brew install --cask --force`, which cannot be skipped by any record, and deliberately
/// installs the *same* version — so there the version string carries no information about
/// whether the bundle was replaced, and the healthy outcome is exactly the one flagged.
@Suite("Adoption installs the same version on purpose")
@MainActor
struct AdoptionSameVersionVerificationTests {

    // MARK: harness

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("adoption-same-version-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeApp(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// Every canary except the arrival gate is satisfied, so the verdict isolates that gate.
    private func passingDependencies() -> CaskRollbackGuard.Dependencies {
        CaskRollbackGuard.Dependencies(
            teamIDBeforeMutation: { _ in "TEAM" },
            teamIDAfterMutation: { _ in "TEAM" },
            recordTeamID: { _, teamID in .unchanged(teamID: teamID) },
            applyRollbackLedger: { _, _ in },
            clone: { _, _ in },
            bundleIdentifier: { _ in "com.example.app" },
            passesGatekeeper: { _ in true },
            restore: { _, _ in },
            helperIsEnabled: { false },
            helperReplace: { _, _ in },
            removeItem: { _ in },
            smokeTestIsEnabled: { false },
            launchSmokeTest: { _ in .survived }
        )
    }

    // MARK: the regression

    /// Red before the fix: the adoption entry point shares the upgrade path's arrival gate, so
    /// two bundles reporting 3.0.2 return `.notUpgraded` and the migration reports failure for
    /// an install that in fact succeeded.
    @Test func adoptingAnAppAtTheCaskVersionIsHealthy() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("snapshot/Proton Drive.app", isDirectory: true)
        let installed = root.appendingPathComponent("Applications/Proton Drive.app", isDirectory: true)
        try makeApp(at: snapshot, version: "3.0.2")
        try makeApp(at: installed, version: "3.0.2")

        let verdict = await CaskRollbackGuard.verify(
            token: "proton-drive",
            snapshotURL: snapshot,
            validationURL: installed,
            expectedTeamID: "TEAM",
            expectedBundleIdentifier: "com.example.app",
            dependencies: passingDependencies()
        )

        #expect(verdict == .healthy,
                "a forced reinstall of the version already on disk is what adoption is for")
    }

    /// The other half of the contract: the gate this fix narrows must keep firing where it was
    /// built to fire — `brew upgrade`, whose target version differs by definition, so an
    /// unchanged one still means brew never touched the disk (the Obsidian 1.13.6 loop).
    @Test func anUpgradeThatLeavesTheSameVersionIsStillANoOp() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("snapshot/Obsidian.app", isDirectory: true)
        let installed = root.appendingPathComponent("Applications/Obsidian.app", isDirectory: true)
        try makeApp(at: snapshot, version: "1.13.6")
        try makeApp(at: installed, version: "1.13.6")

        let store = UpdateOperationStore(rootDirectory: root.appendingPathComponent("operations"))
        let operation = store.begin(trigger: .manual)
        operation.recordPlanned(tokens: ["obsidian"], appPaths: ["obsidian": installed])
        operation.recordSnapshotted(token: "obsidian", snapshotName: "Obsidian.app")
        operation.recordInstalling()

        let outcomes = await CaskRollbackGuard.verify(
            tokens: ["obsidian"],
            appPaths: ["obsidian": installed],
            snapshots: ["obsidian": snapshot],
            operation: operation,
            dependencies: passingDependencies()
        )

        #expect(outcomes == ["obsidian": .notUpgraded],
                "an upgrade that left the pre-upgrade version on disk installed nothing")
    }
}
