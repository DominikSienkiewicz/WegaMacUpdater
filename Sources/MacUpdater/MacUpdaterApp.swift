import SwiftUI
import MacUpdaterCore

@main
struct WegaMacUpdaterApp: App {
    @StateObject private var model = AppViewModel()
    @StateObject private var localization = LocalizationManager.shared
    @StateObject private var policies = UpdatePolicyStore.shared

    init() {
        HomebrewEnvironment.bootstrapAskpass()
    }

    var body: some Scene {
        WindowGroup {
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
    }
}
