import SwiftUI
import MacUpdaterCore

@main
struct WegaMacUpdaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()
    @StateObject private var localization = LocalizationManager.shared
    @StateObject private var policies = UpdatePolicyStore.shared
    @StateObject private var menuBar = MenuBarAgent.shared
    /// Held here, above `.id(localization.language)`, so a language switch re-keys the
    /// view tree without discarding scan results or a running upgrade.
    @StateObject private var scan = ScanStore()

    init() {
        HomebrewEnvironment.bootstrapAskpass()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(localization)
                .environmentObject(policies)
                .environmentObject(scan)
                // Re-key the whole tree on language change so every tr(...) re-evaluates.
                .id(localization.language)
                .task {
                    await model.refreshSystemStatus()
                }
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowToolbarStyle(.unified)
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(localization)
                .environmentObject(policies)
                .id(localization.language)
        }

        MenuBarExtra {
            MenuBarContent(agent: menuBar)
                .environmentObject(localization)
        } label: {
            MenuBarLabel(count: menuBar.updateCount, isChecking: menuBar.isChecking)
        }
    }
}

/// Keeps the process (and its menu-bar item) alive after the window is closed, and
/// kicks off the background update loop on launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        MenuBarAgent.shared.start()
        refreshAppCatalog()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Fire-and-forget refresh of the `AppCatalog` overlay from its canonical source.
    /// ETag-conditional, so repeat launches are cheap; any failure is logged, never
    /// fatal. The fetched overlay is applied on the next launch (the catalog loads
    /// once per process), keeping per-app mappings current without shipping a build.
    private func refreshAppCatalog() {
        Task.detached(priority: .background) {
            let outcome = await CatalogRefresher(source: AppEndpoints.shared.appCatalogURL).refresh()
            AppLogger.app.debug("app-catalog refresh: \(String(describing: outcome), privacy: .public)")
        }
    }
}
