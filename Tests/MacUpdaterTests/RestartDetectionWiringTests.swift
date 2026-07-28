import Foundation
import Testing

/// REL-15 — guards that the window's restart-after-update detection is wired to the generic
/// bundle-URL path (`RunningCaskDetector`) and consults the 16-token map only as an override,
/// mirroring the migration flow's own "not `restartMap`" guard. A pure `RunningCaskDetector`
/// test proves the logic; this proves production actually routes through it.
@Suite("Restart-after-update detection wiring")
struct RestartDetectionWiringTests {
    @Test func foregroundDetectionIsGenericAndUsesTheMapOnlyAsOverride() throws {
        let text = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/ScanStore+Updating.swift"),
            encoding: .utf8
        )
        let start = try #require(text.range(of: "private func runUpdateCoordinated("))
        let end = try #require(
            text.range(of: "private func report(run:", range: start.upperBound..<text.endIndex)
        )
        let body = String(text[start.lowerBound..<end.lowerBound])

        // Detection is generic — by bundle URL, across the whole catalog.
        #expect(body.contains("RunningCaskDetector.runningApps("))
        #expect(body.contains("runningApplicationInspector.runningApplications()"))
        // The 16-token map is passed only as an override, never as the detection gate.
        #expect(body.contains("overrides: MacUpdaterConstants.restartMap"))
        #expect(!body.contains("restartMap["))
        #expect(!body.contains("isProcessRunning"))
    }

    @Test func scanStoreExposesAnInjectableRunningApplicationInspector() throws {
        let text = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/ScanStore.swift"),
            encoding: .utf8
        )
        #expect(text.contains("runningApplicationInspector: any RunningApplicationInspecting"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
