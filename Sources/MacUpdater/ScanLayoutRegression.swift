#if DEBUG
import AppKit
import MacUpdaterCore

extension ScanStore {
    /// Whether this process was started by the subprocess layout-regression test.
    ///
    /// Read in two places: the scenario itself, and `startLaunchRefresh()`, which stands down
    /// for it — the scenario walks `status` through the transition by hand, and a real scan
    /// racing it would be assigning the same property from the other side.
    static var layoutRegressionScenarioRequested: Bool {
        ProcessInfo.processInfo.environment["WEGA_LAYOUT_REGRESSION_TEST"] == "1"
    }

    /// Drives the real app scene through the transition captured in the July 22 crash report.
    /// Enabled only in debug builds and only for the subprocess regression test.
    @MainActor
    func runLayoutRegressionScenarioIfRequested() async -> Bool {
        guard Self.layoutRegressionScenarioRequested else { return false }
        // The test's own `HOME` does not reach `UserDefaults`: cfprefsd keeps this executable's
        // domain under the real home, so a destination left by an earlier run or a `swift run`
        // would otherwise be the one measured. Start on Updates; put the old one back on the way out.
        let previousSelection = UserDefaults.standard.string(forKey: SidebarSelection.storageKey)
        UserDefaults.standard.set(SidebarSelection.initial.rawValue, forKey: SidebarSelection.storageKey)

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
                path: SystemPaths.applicationsDirectory.appendingPathComponent("Google Chrome.app"),
                installedVersion: "150.0.7871.182",
                availableVersion: "151.0.7922.34",
                source: .chrome
            ),
            ManualOutdatedApp(
                name: "Obsidian",
                path: SystemPaths.applicationsDirectory.appendingPathComponent("Obsidian.app"),
                installedVersion: "1.13.1",
                availableVersion: "1.13.3",
                source: .obsidian,
                origin: .brew
            )
        ]
        caskIconPaths = [
            "codex": SystemPaths.applicationsDirectory.appendingPathComponent("Codex.app"),
            "discord": SystemPaths.applicationsDirectory.appendingPathComponent("Discord.app")
        ]
        caskProtection = ["codex": .unprotected(.noAppBundle), "discord": .protected]
        lastCheck = Date()
        status = .results
        progress = .finished
        replayLastScan()

        // ⌘F's field rides on a hidden view mounted only on Updates, because `UpdateView` stays
        // mounted everywhere: one toolbar field on Updates, and still one on Logs.
        try? await Task.sleep(for: .seconds(1))
        let onUpdates = Self.toolbarSearchFieldCount()
        UserDefaults.standard.set(SidebarSelection.logs.rawValue, forKey: SidebarSelection.storageKey)
        try? await Task.sleep(for: .seconds(1))
        let onLogs = Self.toolbarSearchFieldCount()
        UserDefaults.standard.set(previousSelection, forKey: SidebarSelection.storageKey)
        UserDefaults.standard.synchronize()
        if onUpdates != 1 { exit(3) }
        if onLogs != 1 { exit(4) }
        NSApplication.shared.terminate(nil)
        return true
    }

    /// The search fields in the windows' toolbars, however SwiftUI wraps `.searchable`'s field.
    private static func toolbarSearchFieldCount() -> Int {
        NSApplication.shared.windows
            .compactMap(\.toolbar)
            .flatMap(\.items)
            .filter { $0 is NSSearchToolbarItem || $0.view.map(containsSearchField) == true }
            .count
    }

    private static func containsSearchField(_ view: NSView) -> Bool {
        view is NSSearchField || view.subviews.contains(where: containsSearchField)
    }
}
#endif
