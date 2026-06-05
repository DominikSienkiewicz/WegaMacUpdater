import SwiftUI
import MacUpdaterCore

@main
struct WegaMacUpdaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()
    @StateObject private var localization = LocalizationManager.shared
    @StateObject private var policies = UpdatePolicyStore.shared
    @StateObject private var menuBar = MenuBarAgent.shared

    init() {
        HomebrewEnvironment.bootstrapAskpass()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(localization)
                .environmentObject(policies)
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
