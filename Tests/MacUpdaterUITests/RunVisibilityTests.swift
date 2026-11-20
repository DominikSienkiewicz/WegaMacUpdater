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
                  run: UpgradeProgress(completedUnits: 1, totalUnits: 4, stage: .installing(token: nil)))
        #expect(p.statusText == trf("Aktualizuję %@ z %@…", "1", "4"))
    }

    @Test func aWindowRunIsPublishedToTheMenuBarAgent() throws {
        let store = try source("Sources/MacUpdater/ScanStore.swift")
        #expect(store.contains("MenuBarAgent.shared.windowRun"))
    }
}
