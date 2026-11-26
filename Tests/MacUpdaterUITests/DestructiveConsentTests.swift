import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

@Suite("Destructive consent") @MainActor
struct DestructiveConsentTests {
    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func app(_ name: String, brew: Bool = false) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: brew ? name.lowercased() : nil
        )
    }

    private func counts(brew: Int, trash: Int) -> UninstallDialogCounts {
        let brewApps = (0..<brew).map { app("Brew\($0)", brew: true) }
        let trashApps = (0..<trash).map { app("Plain\($0)") }
        let targets = brewApps + trashApps
        let routes = Dictionary(uniqueKeysWithValues: trashApps.map { ($0.id, UninstallRouteDecision.userTrash) })
        return UninstallDialogCounts(targets: targets, routes: routes)
    }

    @Test func returnNeverConfirmsADestructiveUninstall() throws {
        let view = try source("Sources/MacUpdater/UninstallView.swift")
        let destructive = try #require(view.range(of: "Button(confirmLabel, role: .destructive)"))
        let tail = view[destructive.upperBound...].prefix(200)
        #expect(!tail.contains(".keyboardShortcut(.defaultAction)"))
    }

    @Test func restartAsksTheAppToQuitBeforeAnyForce() throws {
        let store = try source("Sources/MacUpdater/ScanStore+Updating.swift")
        #expect(store.contains("requestGracefulTermination"))
        #expect(!store.contains("await processes.kill("))
        #expect(store.contains("pendingForceRestart ="))
    }

    @Test func mixedRemovalConfirmationNamesTheAppsAndLocalItemsGoingToTrash() throws {
        let scope = UninstallScopeSummary.headline(counts: counts(brew: 1, trash: 1), leftovers: 3)
        #expect(scope == "Usuń 2 aplikacje i przenieś 3 pozycje do Kosza")
        let view = try source("Sources/MacUpdater/UninstallView.swift")
        let footer = try #require(view.components(separatedBy: "private var confirmLabel: String {").last)
        #expect(footer.contains("UninstallScopeSummary."))
        #expect(!footer.contains("Usuń tylko aplikację"))
    }

    @Test func confirmationDistinguishesPermanentHomebrewCleanupFromTrashingLocalFiles() {
        let scope = UninstallScopeSummary.headline(counts: counts(brew: 2, trash: 1), leftovers: 1, permanentCleanupCount: 1)
        #expect(scope.contains("trwale"))
        #expect(scope.contains("1 pakietu Homebrew"))
        #expect(scope.contains("1 pozycję do Kosza"))
    }

    @Test func theFooterNamesEveryRoute() {
        let summary = UninstallScopeSummary.text(counts: counts(brew: 1, trash: 2), leftovers: 3, zapMode: true)
        #expect(summary == trf("Do Kosza: %@ · Homebrew: %@ (resztki z zap nie trafiają do Kosza)", "\(2 + 3)", "1"))
    }

    @Test func theFooterNamesOnlyTheRoutesInUse() {
        #expect(UninstallScopeSummary.text(counts: counts(brew: 0, trash: 2), leftovers: 0, zapMode: false)
                == trf("Do Kosza: %@", "2"))
        #expect(UninstallScopeSummary.text(counts: counts(brew: 1, trash: 0), leftovers: 0, zapMode: false)
                == trf("Homebrew: %@", "1"))
    }

    private final class Calls: @unchecked Sendable {
        var log: [String] = []
        var running = true
        var stopsAfterPolls: Int?
        var polls = 0
        var killSucceeds = true
    }

    private nonisolated func flow(_ calls: Calls, accepts: Bool) -> RestartFlow {
        RestartFlow(
            requestQuit: { _ in calls.log.append("quit"); return accepts },
            isRunning: { _ in
                calls.polls += 1
                if let stop = calls.stopsAfterPolls, calls.polls >= stop { calls.running = false }
                return calls.running
            },
            launch: { name in calls.log.append("launch \(name)") },
            pause: { _ in },
            forceKill: { _ in
                calls.log.append("kill")
                if calls.killSucceeds { calls.running = false }
                return calls.killSucceeds
            }
        )
    }

    private let info = RestartInfo(processName: "TextEdit", appName: "TextEdit")

    @Test func aRefusingAppIsNeverRelaunchedOrForcedByTheFlow() async {
        let calls = Calls()
        let outcome = await flow(calls, accepts: true).run(info)
        #expect(outcome == .needsForce)
        #expect(calls.log == ["quit"])
        #expect(calls.polls == 21)
    }

    @Test func anAppThatQuitsInTimeIsRelaunched() async {
        let calls = Calls()
        calls.stopsAfterPolls = 3
        let outcome = await flow(calls, accepts: true).run(info)
        #expect(outcome == .relaunched)
        #expect(calls.log == ["quit", "launch TextEdit"])
    }

    @Test func aQuitRequestThatIsNotDeliveredAsksForConsentAtOnce() async {
        let calls = Calls()
        let outcome = await flow(calls, accepts: false).run(info)
        #expect(outcome == .needsForce)
        #expect(calls.polls == 1)
    }

    @Test func anAppThatIsAlreadyClosedIsRelaunchedWithoutAskingToQuit() async {
        let calls = Calls()
        calls.running = false
        let outcome = await flow(calls, accepts: false).run(info)
        #expect(outcome == .relaunched)
        #expect(calls.log == ["launch TextEdit"])
    }

    @Test func theRestartAlertDefaultsToLeavingTheAppOpen() throws {
        let view = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let keep = try #require(view.range(of: "Button(tr(\"Zostaw otwartą\")"))
        let force = try #require(view.range(of: "role: .destructive"))
        #expect(keep.lowerBound < force.lowerBound)
        #expect(!view.contains("if !shown, let info = pendingForce { onKeepOpen(info) }"))
    }

    /// F4 — Return can never force-quit, and Escape still leaves the app open: no button in the
    /// restart alert carries a keyboard shortcut. Checked on macOS 27 with a scratch probe:
    /// without one, „Wymuś zamknięcie” gets no key, „Zostaw otwartą” (cancel role) gets Escape,
    /// and Return does nothing. `.defaultAction` on „Zostaw otwartą” gave it Return but took
    /// Escape away, so the owner chose to keep Escape.
    @Test func noRestartAlertButtonCarriesAShortcut() throws {
        let view = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let alert = try #require(view.range(of: "trf(\"%@ nie chce się zamknąć.\""))
        let message = try #require(view.range(of: "} message:", range: alert.upperBound..<view.endIndex))
        let buttons = view[alert.upperBound..<message.lowerBound]
        #expect(buttons.contains("Button(tr(\"Wymuś zamknięcie\"), role: .destructive)"), "sanity: the slice holds the buttons")
        #expect(buttons.contains("Button(tr(\"Zostaw otwartą\"), role: .cancel)"))
        #expect(!buttons.contains(".keyboardShortcut("), "F4: no alert button may carry a shortcut")
    }

    /// I6 — an alert dismissed without either button leaves the app open and clears the prompt,
    /// instead of leaving `pendingForceRestart` set behind a closed alert. It records no answer:
    /// SwiftUI also sets the binding after „Wymuś zamknięcie”, so the setter must not say
    /// „Zostaw otwartą” (that is `onKeepOpen`, which only the button calls).
    @Test func dismissingTheAlertLeavesTheAppOpen() {
        var dismissed: [RestartInfo] = []
        var kept = 0
        let section = RestartSection(
            candidates: [info], busyProcess: nil, onRestart: { _ in },
            pendingForce: info, onForce: { _ in }, onKeepOpen: { _ in kept += 1 },
            onDismissForcePrompt: { dismissed.append($0) }
        )
        #expect(section.forcePromptPresented.wrappedValue)
        section.forcePromptPresented.wrappedValue = true
        #expect(dismissed.isEmpty)
        section.forcePromptPresented.wrappedValue = false
        #expect(dismissed == [info])
        #expect(kept == 0)
    }

    @Test func theStoreClearsOnlyThePromptThatWasDismissed() {
        let store = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "", stderr: "") }).store
        store.pendingForceRestart = info
        store.dismissForceRestartPrompt(RestartInfo(processName: "Other", appName: "Other"))
        #expect(store.pendingForceRestart == info, "a stale dismissal leaves a newer prompt alone")
        store.dismissForceRestartPrompt(info)
        #expect(store.pendingForceRestart == nil)
    }

    @Test func aForcedAppIsRelaunched() async {
        let calls = Calls()
        #expect(await flow(calls, accepts: true).force(info) == .relaunched)
        #expect(calls.log == ["kill", "launch TextEdit"])
    }

    /// M1 — the app quit on its own while the alert was up, so `killall` found nothing and
    /// failed. That is not a failure to close it: it is closed, and gets relaunched.
    @Test func aForceThatFindsTheAppAlreadyGoneStillRelaunches() async {
        let calls = Calls()
        calls.killSucceeds = false
        calls.running = false
        #expect(await flow(calls, accepts: true).force(info) == .relaunched)
        #expect(calls.log == ["kill", "launch TextEdit"])
    }

    @Test func aForceThatCannotCloseARunningAppSaysSo() async {
        let calls = Calls()
        calls.killSucceeds = false
        #expect(await flow(calls, accepts: true).force(info) == .stillRunning)
        #expect(calls.log == ["kill"], "an app that is still running is never launched a second time")
    }
}
