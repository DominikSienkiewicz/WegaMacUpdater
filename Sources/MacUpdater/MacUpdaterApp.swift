import SwiftUI
import AppKit
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

    // Deliberately no `init()`. The askpass helper and the sudo shim used to be written into
    // Application Support here, on every launch, before the user had authorised anything.
    // `HomebrewEnvironment.environment` now installs them lazily, on the way to the first
    // brew invocation that actually needs them (M3c).

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(localization)
                .environmentObject(policies)
                .environmentObject(scan)
                // Re-key the whole tree on language change so every tr(...) re-evaluates.
                .id(localization.language)
                .tint(Color.wegaHoney)
                .task {
#if DEBUG
                    if await scan.runLayoutRegressionScenarioIfRequested() { return }
#endif
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

    /// The two AppKit touch-points of the REL-06 quit path, held as properties so a test can
    /// stand in for them: an alert needs a running event loop, and
    /// `reply(toApplicationShouldTerminate:)` only means anything inside AppKit's own
    /// termination sequence. Production values are the real ones.
    var confirmQuitDuringMutation: @MainActor (String) -> QuitDuringMutationChoice = AppDelegate.askWhetherToWait
    var replyToTermination: @MainActor (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }

    func applicationDidFinishLaunching(_: Notification) {
        registerMutationSources()
        MenuBarAgent.shared.start()
        refreshAppCatalog()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// REL-06 — ⌘Q, "Zakończ Wega", log-out and shutdown all arrive here. Without this
    /// method they ended the process on the spot, including halfway through `brew upgrade
    /// --cask`: the old bundle already moved aside, the new one not yet in place.
    ///
    /// A mutation in flight makes the quit a question rather than an order. The reply is
    /// deferred (`.terminateLater`, never `.terminateCancel` — ⌘Q must not silently do
    /// nothing) until the user has answered and, if they chose to wait, until the mutation
    /// has actually finished.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        switch MutationGuard.shared.terminationDecision() {
        case .now:
            return .terminateNow
        case .waitForMutation:
            resolveQuitDuringMutation()
            return .terminateLater
        }
    }

    /// `UpgradeMutex` is owned by the upgrade paths (`ScanStore.runUpdate` and the
    /// background round) and only exposes a boolean, so it joins the guard as a probe.
    private func registerMutationSources() {
        MutationGuard.shared.addProbe(tr("aktualizacja Homebrew")) { UpgradeMutex.shared.isBusy }
    }

    /// Every branch has to end in a reply — a `.terminateLater` that never answers is a
    /// log-out that hangs until macOS force-quits the app.
    private func resolveQuitDuringMutation() {
        let running = MutationGuard.shared.runningLabels.joined(separator: ", ")
        switch confirmQuitDuringMutation(running) {
        case .waitForMutation:
            WegaLog.info(.app, "Zamknięcie odroczone — czekam na zakończenie: \(running)")
            Task { @MainActor in
                await MutationGuard.shared.waitUntilIdle()
                WegaLog.info(.app, "Mutacja zakończona — zamykam Wegę.")
                self.replyToTermination(true)
            }
        case .quitAnyway:
            WegaLog.warning(.app, "Zamknięcie mimo trwającej mutacji: \(running)")
            replyToTermination(true)
        case .cancel:
            replyToTermination(false)
        }
    }

    private static func askWhetherToWait(running: String) -> QuitDuringMutationChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("Wega jest w trakcie zmiany")
        alert.informativeText = running.isEmpty
            ? tr("Zamknięcie teraz może zostawić aplikację w połowie zainstalowanej.")
            : trf("Trwa: %@. Zamknięcie teraz może zostawić aplikację w połowie zainstalowanej.", running)
        alert.addButton(withTitle: tr("Poczekaj na zakończenie"))
        alert.addButton(withTitle: tr("Zakończ mimo to"))
        alert.addButton(withTitle: tr("Anuluj"))
        NSApplication.shared.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .waitForMutation
        case .alertSecondButtonReturn: return .quitAnyway
        default:                       return .cancel
        }
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
