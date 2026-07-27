import Foundation
import Testing

@testable import MacUpdaterCore

/// ARCH-08c — licznik po aktualizacji w tle korzysta z już wykonanego skanu.
///
/// Agent uruchamiał **drugi pełny skan** — brew, mas, npm i wszystkie checkery ręczne — tylko
/// po to, żeby odświeżyć plakietkę po zaktualizowaniu kilku casków, które sam przed chwilą
/// zaktualizował. W aplikacji menu-bar działającej non-stop to drugi wachlarz procesów i sond
/// sieciowych na każdą rundę, po informację, którą już się ma.
@Suite("ARCH-08c reused scan")
struct ReusedScanAfterBackgroundRoundTests {

    private func result(casks: [String], manual: Int = 0) -> MenuBarScanResult {
        MenuBarScanResult(
            brew: BrewOutdated(formulae: [], casks: casks.map {
                BrewOutdatedItem(name: $0, installedVersions: ["1.0"], currentVersion: "2.0")
            }),
            mas: [], npm: [],
            manualApps: (0..<manual).map {
                ManualOutdatedApp(name: "Manual\($0)", path: URL(fileURLWithPath: "/Applications/M\($0).app"),
                                  installedVersion: "1.0", availableVersion: "2.0", source: .sparkle)
            },
            failedChecks: 0, scannedAt: Date(), total: casks.count + manual
        )
    }

    @Test func upgradedCasksLeaveTheListAndTheCount() {
        let after = result(casks: ["docker", "slack", "zoom"]).removingUpgradedCasks(["docker", "slack"])

        #expect(after.brew?.casks.map(\.name) == ["zoom"])
        #expect(after.total == 1)
    }

    /// Aktualizacja casku nie zmienia tego, co zgłosiłyby mas, npm ani checkery ręczne —
    /// te pozycje muszą przetrwać nietknięte, inaczej licznik zacząłby gubić aktualizacje.
    @Test func everythingOutsideHomebrewSurvivesUntouched() {
        let after = result(casks: ["docker"], manual: 2).removingUpgradedCasks(["docker"])

        #expect(after.manualApps.count == 2)
        #expect(after.total == 2)
    }

    @Test func anEmptyUpgradeListChangesNothing() {
        let before = result(casks: ["docker"], manual: 1)

        #expect(before.removingUpgradedCasks([]) == before)
    }

    /// Nazwa, której nie było na liście, nie może niczego usunąć ani przekłamać licznika.
    @Test func anUnknownNameIsIgnored() {
        let after = result(casks: ["docker"]).removingUpgradedCasks(["nie-bylo-takiego"])

        #expect(after.brew?.casks.count == 1)
        #expect(after.total == 1)
    }
}
