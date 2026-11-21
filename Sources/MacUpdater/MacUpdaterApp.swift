import SwiftUI
import AppKit
import MacUpdaterCore

// The entry point is `WegaMain` (ResourceSelfCheck.swift), which forwards here after handling
// the pipeline's resource probe. `@main` cannot sit on both.
struct WegaMacUpdaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()
    @StateObject private var localization = LocalizationManager.shared
    @StateObject private var policies = UpdatePolicyStore.shared
    @StateObject private var menuBar = MenuBarAgent.shared
    /// UX-10 — bus for menu commands that must reach a not-yet-mounted view (⌘F and ⇧⌘F → a
    /// screen's search field). Held above the language re-key so a request pending across a
    /// switch is not lost.
    @StateObject private var commandCenter = WegaCommandCenter()
    /// Held here, above `.id(localization.language)`, so a language switch re-keys the
    /// view tree without discarding scan results or a running upgrade.
    @StateObject private var scan = ScanStore()
    /// The inventory read, held above the language re-key like `scan`: leaving the screen and
    /// coming back shows the result again instead of reading every folder anew (UXP-30).
    @StateObject private var inventory = InventoryStore()
    /// Migration can remain active while `.id(localization.language)` rebuilds its view.
    @StateObject private var migration = MigrationStore()
    /// Cleanup ("Porządki") keeps a running scan or removal, and its last report, across the
    /// language re-key below.
    @StateObject private var cleanup = CleanupStore()
    /// Whether the detail column shows its inspector. Held here, above the language re-key, so a
    /// switch does not close a panel the user opened. `@State` on the scene — never persisted —
    /// keeps every launch starting closed, which `ContentView.showsInspectorAtLaunch` demands.
    @State private var showInspector: Bool = ContentView.showsInspectorAtLaunch

    // Deliberately no `init()`. The askpass helper and the sudo shim used to be written into
    // Application Support here, on every launch, before the user had authorised anything.
    // `HomebrewEnvironment.environment` now installs them lazily, on the way to the first
    // brew invocation that actually needs them (M3c).

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(showInspector: $showInspector)
                .environmentObject(model)
                .environmentObject(localization)
                .environmentObject(policies)
                .environmentObject(scan)
                .environmentObject(inventory)
                .environmentObject(migration)
                .environmentObject(cleanup)
                .environmentObject(commandCenter)
                // Re-key the whole tree on language change so every tr(...) re-evaluates.
                .id(localization.language)
                .tint(Color.wegaHoneyFill)
                .task {
#if DEBUG
                    if await scan.runLayoutRegressionScenarioIfRequested() { return }
#endif
                }
                .onReceive(HelperLeftoverRegistrationCleanup.shared.$removedRegistration) { removed in
                    if removed, HelperLeftoverRegistrationCleanup.shared.consumeNotice() { scan.showStickyBanner(HelperLeftoverRegistrationCleanup.banner) }
                }
        }
        .windowToolbarStyle(.unified)
        .windowStyle(.titleBar)
        // UX-10 — the app's `CommandMenu` and its keyboard shortcuts (⌘R, ⌘⏎, ⌘1…⌘7, ⌘F and the rest).
        // The menu itself is `WegaCommands`; it reads `@FocusedValue`s the view tree publishes,
        // which a `Commands` conformer can do and this `.commands` closure cannot.
        .commands {
            WegaCommands(commandCenter: commandCenter)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(localization)
                .environmentObject(policies)
                .id(localization.language)
        }
        // UX-03 — a Settings window whose content is fixed-size cannot be resized at all.
        // `.contentSize` lets the frame's ideal size open the window and its min/max let the
        // user (or a larger system text size) grow it.
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent(agent: menuBar)
                .environmentObject(localization)
        } label: {
            MenuBarLabel(status: MenuBarStatusPresentation(
                count: menuBar.updateCount, isChecking: menuBar.isChecking, failed: menuBar.lastCheckFailed,
                incomplete: menuBar.lastCheckIncomplete, lastCheck: menuBar.lastCheck, run: menuBar.windowRun,
                windowScanning: menuBar.windowScanRunning
            ))
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
        guard enforceSingleInstance() else { return }
        // LT-05: attach the MetricKit source first thing. A diagnostic recorded by a previous
        // run is delivered shortly after launch, so a late subscription can miss the very
        // crash it exists to capture. Attaching does not subscribe — the controller starts
        // delivery only if the user has opted in.
        CrashReportingController.shared.attach(source: MetricKitCrashDiagnosticSource())
        // OBS-02 — before anything can be clicked. A notification delivered while no delegate
        // is set is dropped, not queued, so a late install loses the very click it exists for.
        NotificationRouter.install()
        registerMutationSources()
        // LT-01 — settle whatever a crash, kill or power loss left mid-upgrade *before*
        // the background agent starts scheduling new rounds over an unknown disk state.
        // The agent's start is deferred until recovery is done; a typical launch has
        // nothing to settle and pays nothing.
        Task { @MainActor in
            await UpdateOperationRecovery.shared.recoverInterruptedOperations()
            MenuBarAgent.shared.start()
        }
        // Z14: a helper registration left from a copy Wega may not use is removed at launch.
        Task { @MainActor in await HelperLeftoverRegistrationCleanup.shared.run() }
        refreshAppCatalog()
    }

    /// REL-08 — a second copy of Wega would drive `brew` in parallel with the first and race
    /// for its lock, exactly the half-written Caskroom the in-process coordinator prevents.
    /// `UpgradeMutex`/`OperationCoordinator` cannot see another process, so the guard is here,
    /// at launch: count the other running copies by bundle identifier (this process excluded)
    /// and, if any exist, stand down before touching any mutation source. Returns `false` when
    /// this instance must not continue starting up.
    private func enforceSingleInstance() -> Bool {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: AppMetadata.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        switch SingleInstanceGuard.decide(otherInstanceCount: others.count) {
        case .proceed:
            return true
        case .anotherInstanceRunning:
            WegaLog.warning(.app, "Druga instancja Wega wykryta — kończę, aby nie mutować brew równolegle.")
            #if DEBUG
            // A clean exit here would let the layout test pass without running its scenario.
            if ScanStore.layoutRegressionScenarioRequested { exit(5) }
            #endif
            NSApp.terminate(nil)
            return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// REL-06 — ⌘Q, "Zakończ Wegę", log-out and shutdown all arrive here. Without this
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
            WegaLog.debug(.app, "app-catalog refresh: \(String(describing: outcome))")
        }
    }
}
