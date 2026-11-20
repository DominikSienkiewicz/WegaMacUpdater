import Combine
import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// UXP-09 — the running update and an honest stop are visible from every screen.
@Suite("Run visibility") @MainActor
struct RunVisibilityTests {
    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func theStopLabelSaysActiveInstallsFinish() {
        #expect(UpdateRunCopy.stopLabel(isStopping: false) == tr("Zatrzymaj po rozpoczętych instalacjach"))
        #expect(UpdateRunCopy.stopLabel(isStopping: true) == tr("Kończę rozpoczęte instalacje, nowych nie zaczynam"))
    }

    @Test func aRunReportsUpdatingNotScanning() throws {
        let store = try source("Sources/MacUpdater/ScanStore+Updating.swift")
        #expect(store.contains("emitActivitySignal(.updating)"))
    }

    @Test func stopIsInTheMenuUnderCommandPeriod() throws {
        let commands = try source("Sources/MacUpdater/WegaCommands.swift")
        #expect(commands.contains(".keyboardShortcut(\".\", modifiers: .command)"))
    }

    @Test func theMenuBarShowsAWindowRun() {
        let p = MenuBarStatusPresentation(count: 4, isChecking: false, failed: false, incomplete: false, lastCheck: .now,
                  run: WindowRunStatus(completedUnits: 1, totalUnits: 4, isStopping: false))
        #expect(p.statusText == trf("Aktualizuję %@ z %@…", "1", "4"))
    }

    @Test func aWindowRunIsPublishedToTheMenuBarAgent() throws {
        let store = try source("Sources/MacUpdater/ScanStore.swift")
        #expect(store.contains("MenuBarAgent.shared.windowRun"))
    }

    /// I3 — the brew loop assigns `upgradeProgress` on every output chunk. Republishing each
    /// one re-evaluated the whole `App` body and every observer of the agent for a value the
    /// menu draws identically; only a change of done/total (or of the stop) gets through now.
    @Test func identicalProgressIsNotRepublishedToTheMenuBar() {
        let store = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "") }).store
        let agent = MenuBarAgent.shared
        agent.windowRun = nil
        defer { agent.windowRun = nil }
        var emissions = 0
        let subscription = agent.objectWillChange.sink { emissions += 1 }
        defer { subscription.cancel() }

        store.upgradeProgress = UpgradeProgress(completedUnits: 1, totalUnits: 4, stage: .installing(token: "a"))
        store.upgradeProgress = UpgradeProgress(completedUnits: 1, totalUnits: 4, stage: .installing(token: "a"))
        store.upgradeProgress = UpgradeProgress(completedUnits: 1, totalUnits: 4, stage: .downloading(token: "b"))
        #expect(emissions == 1, "I3: three chunks of the same package published \(emissions) times")

        store.upgradeProgress = UpgradeProgress(completedUnits: 2, totalUnits: 4, stage: .installing(token: "b"))
        #expect(emissions == 2)
        #expect(agent.windowRun == WindowRunStatus(completedUnits: 2, totalUnits: 4, isStopping: false))
        store.upgradeProgress = nil
        #expect(emissions == 3 && agent.windowRun == nil)
    }

    /// I4 — after a stop from anywhere (⌘., the run bar, the menu) the menu bar still offered
    /// „Zatrzymaj po rozpoczętych instalacjach”, as if the click had done nothing.
    @Test func aStopRequestReachesTheMenuBar() {
        let store = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "") }).store
        let agent = MenuBarAgent.shared
        defer { agent.windowRun = nil }
        store.updating = true
        defer { store.updating = false }
        store.upgradeProgress = UpgradeProgress(completedUnits: 1, totalUnits: 4, stage: .installing(token: nil))
        #expect(agent.windowRun?.isStopping == false)

        store.cancelUpdate()

        #expect(agent.windowRun == WindowRunStatus(completedUnits: 1, totalUnits: 4, isStopping: true))
        store.upgradeProgress = nil
    }

    @Test func theMenuBarStopSaysWhatTheWindowSays() throws {
        let stopping = WindowRunStatus(completedUnits: 1, totalUnits: 4, isStopping: true)
        #expect(stopping.stopLabel == tr("Kończę rozpoczęte instalacje, nowych nie zaczynam") && !stopping.canStop)
        let running = WindowRunStatus(completedUnits: 1, totalUnits: 4, isStopping: false)
        #expect(running.stopLabel == tr("Zatrzymaj po rozpoczętych instalacjach") && running.canStop)

        let menu = try source("Sources/MacUpdater/MenuBarScene.swift")
        #expect(menu.contains("Button(run.stopLabel) { agent.stopWindowRun?() }"))
        #expect(menu.contains(".disabled(!run.canStop)"))
    }
}
