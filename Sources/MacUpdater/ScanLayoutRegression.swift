#if DEBUG
import AppKit
import MacUpdaterCore

extension ScanStore {
    /// Drives the real app scene through the transition captured in the July 22 crash report.
    /// Enabled only in debug builds and only for the subprocess regression test.
    @MainActor
    func runLayoutRegressionScenarioIfRequested() async -> Bool {
        guard ProcessInfo.processInfo.environment["WEGA_LAYOUT_REGRESSION_TEST"] == "1" else {
            return false
        }

        try? await Task.sleep(for: .milliseconds(250))
        status = .checking
        progress = .running(.manual)

        try? await Task.sleep(for: .milliseconds(250))
        brewOutdated = BrewOutdated(
            formulae: [],
            casks: [
                BrewOutdatedItem(
                    name: "codex",
                    installedVersions: ["0.144.6"],
                    currentVersion: "0.145.0"
                ),
                BrewOutdatedItem(
                    name: "discord",
                    installedVersions: ["0.0.401"],
                    currentVersion: "0.0.402"
                )
            ]
        )
        manualOutdated = [
            ManualOutdatedApp(
                name: "Chrome",
                path: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
                installedVersion: "150.0.7871.182",
                availableVersion: "151.0.7922.34",
                source: .chrome
            ),
            ManualOutdatedApp(
                name: "Obsidian",
                path: URL(fileURLWithPath: "/Applications/Obsidian.app"),
                installedVersion: "1.13.1",
                availableVersion: "1.13.3",
                source: .obsidian,
                origin: .brew
            )
        ]
        caskIconPaths = [
            "codex": URL(fileURLWithPath: "/Applications/Codex.app"),
            "discord": URL(fileURLWithPath: "/Applications/Discord.app")
        ]
        caskProtection = ["codex": .unprotected(.noAppBundle), "discord": .protected]
        lastCheck = Date()
        status = .results
        progress = .finished
        replayLastScan()

        try? await Task.sleep(for: .seconds(2))
        NSApplication.shared.terminate(nil)
        return true
    }
}
#endif
