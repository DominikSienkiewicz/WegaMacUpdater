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
            pause: { _ in }
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

    /// I6 — Return never forces: „Zostaw otwartą” is the alert's default button. A scratch
    /// probe on macOS 27 confirmed SwiftUI honours `.defaultAction` on a cancel-role alert
    /// button (it gets Return; the destructive one gets no key at all).
    @Test func returnLeavesTheAppOpen() throws {
        let view = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let keep = try #require(view.range(of: "Button(tr(\"Zostaw otwartą\"), role: .cancel)"))
        #expect(view[keep.upperBound...].prefix(120).contains(".keyboardShortcut(.defaultAction)"),
                "I6: Return must land on „Zostaw otwartą”")
        let force = try #require(view.range(of: "Button(tr(\"Wymuś zamknięcie\"), role: .destructive)"))
        #expect(!view[force.upperBound...].prefix(120).contains(".keyboardShortcut("))
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
}
