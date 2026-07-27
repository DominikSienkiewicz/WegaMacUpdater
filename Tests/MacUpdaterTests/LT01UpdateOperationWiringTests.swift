import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-01 — source-level wiring pins for the app target (not importable from this test
/// bundle): the snapshot chain runs inside journaled operation directories, the healthy
/// path no longer deletes the clone, recovery runs before the background agent starts,
/// and the manual undo restores *then pins*.
@Suite("LT-01 — update operation wiring")
struct LT01UpdateOperationWiringTests {

    private func source(_ name: String, file: String = #filePath) throws -> String {
        let packageRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MacUpdater/\(name)"),
            encoding: .utf8
        )
    }

    /// The pre-LT-01 shape: one shared, predictable temp directory and clones deleted the
    /// moment the canary passed. Both halves had to go for a crash to be recognizable and
    /// for a manual undo to exist.
    @Test func snapshotsLiveInOperationDirectoriesNeverThePredictableTempPath() throws {
        let guardSource = try source("CaskRollbackGuard.swift")
        #expect(!guardSource.contains("temporaryDirectory.appendingPathComponent(\"wega-rollback\""),
                "LT-01: the shared, predictable temp snapshot path must be gone")
        #expect(guardSource.contains("operation.snapshotsDirectory"),
                "LT-01: clones belong to the operation's own unique directory")
        #expect(guardSource.contains("operation.recordSnapshotted(token: token, snapshotName: name)"),
                "LT-01: every confirmed clone is journaled before the next one starts")
    }

    /// A healthy upgrade keeping its snapshot is what makes "Cofnij aktualizację"
    /// possible at all — this is the one deletion LT-01 deliberately removes.
    @Test func healthyUpgradeNoLongerDeletesItsSnapshot() throws {
        let guardSource = try source("CaskRollbackGuard.swift")
        #expect(!guardSource.contains("try? FileManager.default.removeItem(at: snapshotURL)"),
                "LT-01: retention (UpdateOperationStore.pruneExpired) owns the snapshot now")
    }

    @Test func bothBatchUpgradePathsJournalTheirPhases() throws {
        let foreground = try source("ScanStore+Actions.swift") + "\n" + source("ScanStore+Rollback.swift")
        #expect(foreground.contains("UpdateOperationStore.shared.begin(trigger: .manual)"))
        #expect(foreground.contains("caskPreparation.operation.recordInstalling()"),
                "the last journal write before brew is what recovery probes after a crash")

        let background = try source("BackgroundUpdater.swift")
        #expect(background.contains("UpdateOperationStore.shared.begin(trigger: .background)"))
        #expect(background.contains("operation.recordInstalling()"))

        // `installing` must be recorded before the package manager runs — after it, the
        // journal would claim "never ran" about a mutated disk.
        let backgroundInstalling = try #require(background.range(of: "operation.recordInstalling()"))
        let backgroundBrew = try #require(background.range(of: "await runBrew(arguments: arguments)"))
        #expect(backgroundInstalling.lowerBound < backgroundBrew.lowerBound)
    }

    /// Recovery before the agent: a background round scheduled over an unsettled disk is
    /// the race LT-01 exists to prevent.
    @Test func recoveryRunsBeforeTheBackgroundAgentStarts() throws {
        let app = try source("MacUpdaterApp.swift")
        let recovery = try #require(app.range(of: "UpdateOperationRecovery.shared.recoverInterruptedOperations()"))
        let agentStart = try #require(app.range(of: "MenuBarAgent.shared.start()"))
        #expect(recovery.lowerBound < agentStart.lowerBound)
    }

    /// The manual undo: restore through the same code the canary uses, journal it as the
    /// user's own choice, and pin the restored version — without the pin, the next scan
    /// would offer the update the user just took back.
    @Test func manualUndoRestoresThenPinsTheRestoredVersion() throws {
        let undo = try source("ScanStore+Undo.swift")
        let restore = try #require(undo.range(of: "await CaskRollbackGuard.restoreSnapshot(snapshotURL, to: appURL)"))
        let mark = try #require(undo.range(of: "store.markUndoneByUser(operationID: operation.id, token: undoable.token)"))
        let pin = try #require(undo.range(of: "UpdatePolicyStore.shared.pin("))
        #expect(restore.lowerBound < mark.lowerBound,
                "a failed restore must never reach the journal as an undo")
        #expect(mark.lowerBound < pin.lowerBound,
                "the pin is the auto-pin LT-01 requires after a successful undo")
    }

    /// Sources Wega cannot roll back say so in the UI, instead of letting the cask
    /// shield imply a net the other sections do not have.
    @Test func sourcesWithoutRollbackDiscloseTheLimitation() throws {
        let view = try source("UpdateView.swift")
        #expect(view.contains("Bez automatycznego cofnięcia — Homebrew nie zachowuje poprzednich wersji formuł."))
        #expect(view.contains("Bez automatycznego cofnięcia — App Store nie pozwala wrócić do poprzedniej wersji."))
        #expect(view.contains("Bez automatycznego cofnięcia — npm nie zachowuje poprzednich wersji pakietów."))
        #expect(view.contains("Bez automatycznego cofnięcia — poprzednią wersję pobierzesz od wydawcy."))
    }
}
