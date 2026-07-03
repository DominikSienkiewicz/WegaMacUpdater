import XCTest
@testable import MacUpdaterCore

/// The Logs view was too sparse — it reported counts ("N aktualizacji") and bare exit
/// codes ("kod 1") with no *what* or *why*. These pin the pure log formatters that make
/// it informative: per-item lines, a per-source breakdown, the real brew error reason,
/// and per-checker debug lines.
final class ScanLogTests: XCTestCase {
    private func item(_ name: String, _ from: String?, _ to: String?, _ kind: OutdatedItem.Kind) -> OutdatedItem {
        OutdatedItem(key: "k:\(name)", name: name, from: from, to: to, kind: kind)
    }
    private func manual(_ name: String, _ from: String?, _ to: String?, _ source: ManualOutdatedApp.UpdateSource) -> ManualOutdatedApp {
        ManualOutdatedApp(
            name: name, path: URL(fileURLWithPath: "/Applications/\(name).app"),
            installedVersion: from, availableVersion: to, source: source
        )
    }

    // 1. Co znaleziono (lista pozycji)
    func testFoundLinesRenderVersionTransitionAndSource() {
        let lines = ScanLog.foundLines(
            items: [item("little-snitch", "6.4", "6.4.1", .cask)],
            manual: [manual("Docker", "4.78.0", "4.79.0", .cask(token: "docker-desktop")),
                     manual("Postman", "12.15.6", "12.16.0", .postman)]
        )
        XCTAssertEqual(lines, [
            "little-snitch 6.4 → 6.4.1 · Homebrew cask",
            "Docker 4.78.0 → 4.79.0 · Homebrew cask",
            "Postman 12.15.6 → 12.16.0 · Postman (feed)"
        ])
    }

    // 1b. Etykiety źródeł dla samoaktualizujących się aplikacji (Discord/Signal/Chrome)
    func testFoundLinesLabelSelfUpdatingSources() {
        let lines = ScanLog.foundLines(
            items: [],
            manual: [manual("Discord", "1.0.9200", "1.0.9201", .discord),
                     manual("Signal", "7.60.0", "7.61.0", .signal),
                     manual("Google Chrome", "138.0.7204.50", "138.0.7204.92", .chrome)]
        )
        XCTAssertEqual(lines, [
            "Discord 1.0.9200 → 1.0.9201 · Discord",
            "Signal 7.60.0 → 7.61.0 · Signal",
            "Google Chrome 138.0.7204.50 → 138.0.7204.92 · Google Chrome"
        ])
    }

    // 2. Rozbicie skanu na źródła
    func testBreakdownCountsPerSource() {
        let bd = ScanLog.breakdown(
            items: [item("a", "1", "2", .formula), item("ls", "6.4", "6.4.1", .cask)],
            manual: [manual("Docker", "4.78", "4.79", .cask(token: "docker-desktop")),
                     manual("Postman", "1", "2", .postman)]
        )
        XCTAssertEqual(bd, "formuły: 1, caski: 1, MAS: 0, npm: 0, ręczne: 2")
    }

    // 3. Powód błędu, nie tylko kod
    func testBrewErrorReasonPicksTheErrorLine() {
        let log = [
            "==> Fetching downloads for: docker-desktop",
            "==> Installing Cask docker-desktop",
            "Error: It seems there is already an App at '/Applications/Docker.app'.",
            "==> Purging files for version 4.79.0,230596 of Cask docker-desktop"
        ]
        XCTAssertEqual(ScanLog.brewErrorReason(from: log),
                       "Error: It seems there is already an App at '/Applications/Docker.app'.")
    }

    func testBrewErrorReasonNilWhenNoErrorLine() {
        XCTAssertNil(ScanLog.brewErrorReason(from: ["==> Installing", "🍺 Done"]))
    }

    // 4. Tryb debug (per-checker)
    func testCheckerDebugLineSkipsNotApplicable() {
        XCTAssertNil(ScanLog.checkerDebugLine(source: "Sparkle", app: "X", result: .notApplicable, millis: 5))
    }

    func testCheckerDebugLineSkipsAlreadyLoggedFailures() {
        XCTAssertNil(ScanLog.checkerDebugLine(source: "Cask", app: "X", result: .unavailable, millis: 5))
        XCTAssertNil(ScanLog.checkerDebugLine(source: "Cask", app: "X", result: .failed, millis: 5))
    }

    func testCheckerDebugLineForOutdatedShowsTransitionAndTiming() {
        let r = ManualCheckResult.outdated(manual("Postman", "12.15.6", "12.16.0", .postman))
        XCTAssertEqual(ScanLog.checkerDebugLine(source: "Postman", app: "Postman", result: r, millis: 243),
                       "Postman · Postman: 12.15.6→12.16.0 (243 ms)")
    }

    func testCheckerDebugLineForUpToDateShowsTiming() {
        XCTAssertEqual(ScanLog.checkerDebugLine(source: "Sparkle", app: "Transmit", result: .upToDate, millis: 120),
                       "Sparkle · Transmit: aktualna (120 ms)")
    }
}
