import SwiftUI

@main
struct WegaMacUpdaterApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
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
