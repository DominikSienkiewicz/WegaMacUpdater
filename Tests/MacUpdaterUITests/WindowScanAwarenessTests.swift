import Foundation
import MacUpdaterCore
import Testing
import WegaTestSupport
@testable import WegaMacUpdater

@MainActor
private final class FlagRecorder {
    var values: [Bool] = []
}

@Suite("The menu bar knows the window is scanning") @MainActor
struct WindowScanAwarenessTests {
    @Test func theMenuSaysTheWindowIsCheckingAndARunStillWins() {
        withLanguage(.pl) {
            let scanning = MenuBarStatusPresentation(count: 3, isChecking: false, failed: false, incomplete: false, lastCheck: .now, windowScanning: true)
            #expect(scanning.statusText == "Sprawdzam aktualizacje w oknie Wegi…")
            let both = MenuBarStatusPresentation(count: 3, isChecking: false, failed: false, incomplete: false, lastCheck: .now,
                                                 run: WindowRunStatus(completedUnits: 1, totalUnits: 4, isStopping: false), windowScanning: true)
            #expect(both.statusText == "Aktualizuję 1 z 4…")
        }
        withLanguage(.en) {
            #expect(MenuBarStatusPresentation(count: 0, isChecking: false, failed: false, incomplete: false, lastCheck: nil, windowScanning: true)
                .statusText == "Checking for updates in the Wega window…")
        }
    }

    @Test func aWindowScanTellsTheMenuWhenItStartsAndEnds() async {
        let reports = FlagRecorder()
        let harness = makeScanStoreRuntimeHarness(runner: InventoryStalenessTests.idleBrewRunner(),
                                                  onWindowScanRunning: { reports.values.append($0) })
        harness.store.startCheck()
        await harness.store.scanTask?.value
        #expect(reports.values == [true, false])
    }

    @Test func theAgentAssignsOnlyAChange() {
        let (defaults, teardown) = TestDefaults.isolated("window-scan-awareness")
        defer { teardown() }
        let agent = MenuBarAgent(defaults: defaults)
        agent.setWindowScanRunning(true)
        #expect(agent.windowScanRunning && agent.checkInProgress)
        agent.setWindowScanRunning(false)
        #expect(!agent.windowScanRunning && !agent.checkInProgress)
    }

    @Test func theMenuStandsDownWhileTheWindowScans() throws {
        let agent = try source("Sources/MacUpdater/MenuBarAgent.swift")
        #expect(agent.contains("guard !isChecking, !windowScanRunning else { return }"))
        let menu = try source("Sources/MacUpdater/MenuBarScene.swift")
        #expect(menu.contains("MenuBarMenuCopy.checkTitle(isChecking: agent.checkInProgress, consentCount: consents.consents.count)"))
        #expect(menu.contains(".disabled(agent.checkInProgress)"))
        #expect(menu.contains("isChecking: agent.checkInProgress, now: clock.now)"))
        #expect(menu.contains("windowScanning: agent.windowScanRunning"))
        #expect(try source("Sources/MacUpdater/MacUpdaterApp.swift").contains("windowScanning: menuBar.windowScanRunning"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
