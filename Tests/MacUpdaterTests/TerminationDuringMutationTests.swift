import Testing
import Foundation

/// REL-06 — quitting must never cut a Homebrew mutation in half.
///
/// The app had no `applicationShouldTerminate` at all, so ⌘Q, log-out and shutdown ended
/// the process *immediately* — including in the middle of `runUpdate`, a background round,
/// an uninstall or a migration, which is exactly how a Caskroom is left half-written (the
/// old version already moved aside, the new one not yet in place). "Zakończ Wega" in the
/// menu bar made it worse: it called `terminate(nil)` unconditionally, without ever asking
/// `UpgradeMutex` whether something was in flight.
///
/// The decision itself is a pure type — `MacUpdaterCore.MutationGuard`, covered by
/// `MutationGuardTests`. What cannot be reached from a unit test is the *wiring*: the
/// `NSApplicationDelegate` method and the SwiftUI menu item both live in the app target,
/// behind AppKit's termination sequence. So the wiring is asserted where it is checkable —
/// the same source-level guard `MigrationLeftoverCleanupDisabledTests` (SEC-01) and
/// `UpdateResultHonestyTests` (REL-02) use.
@Suite("TerminationDuringMutation")
struct TerminationDuringMutationTests {

    private func packageRoot(file: String = #filePath) -> URL {
        // <root>/Tests/MacUpdaterTests/<thisFile>.swift → up 3 = <root>
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources(under relativePath: String) throws -> [(name: String, text: String)] {
        let root = packageRoot().appendingPathComponent(relativePath)
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { (name: "\(relativePath)/\($0.lastPathComponent)",
                                text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The delegate method has to exist, has to ask the guard, and has to answer
    /// `.terminateLater` — not `.terminateCancel`, which would make ⌘Q look broken.
    @Test func terminationIsDeferredWhileAMutationIsInFlight() throws {
        let text = try source("Sources/MacUpdater/MacUpdaterApp.swift")
        #expect(text.contains("func applicationShouldTerminate("),
                "REL-06: AppDelegate must implement applicationShouldTerminate — without it ⌘Q kills a running brew mutation")
        #expect(text.contains("MutationGuard.shared.terminationDecision()"),
                "REL-06: the reply must come from the mutation guard, not from a local guess")
        #expect(text.contains(".terminateLater"),
                "REL-06: a mutation in flight must defer the quit, not cancel it")
    }

    /// `.terminateLater` without a reply is a hang. The user gets a question, and whichever
    /// button they press ends with `reply(toApplicationShouldTerminate:)`.
    @Test func theDeferredQuitAsksTheUserAndAlwaysReplies() throws {
        let text = try source("Sources/MacUpdater/MacUpdaterApp.swift")
        #expect(text.contains("NSAlert"),
                "REL-06: the user must see a dialog offering to wait for the mutation to finish")
        #expect(text.contains("reply(toApplicationShouldTerminate:"),
                "REL-06: every branch of the dialog must reply, or .terminateLater hangs the log-out")
        #expect(text.contains("waitUntilIdle"),
                "REL-06: choosing to wait must actually wait for the mutation to finish")
    }

    /// Sudden termination bypasses `applicationShouldTerminate` entirely — at log-out the
    /// process can simply be killed. The activity assertion is what makes the delegate
    /// method reachable at all.
    @Test func suddenTerminationIsDisabledWhileMutationsCanRun() throws {
        let sources = try swiftSources(under: "Sources/MacUpdater")
            + swiftSources(under: "Sources/MacUpdaterCore")
        #expect(sources.count > 10, "Sanity: the scan should see the app and core sources")

        let holders = sources.filter { $0.text.contains("suddenTerminationDisabled") }.map(\.name)
        #expect(!holders.isEmpty,
                "REL-06: something must hold ProcessInfo.beginActivity(.suddenTerminationDisabled) while a mutation can run")
    }

    /// "Zakończ Wega" used to be a plain `terminate(nil)`.
    @Test func theMenuBarQuitConsultsTheMutationGuard() throws {
        let text = try source("Sources/MacUpdater/MenuBarScene.swift")
        #expect(text.contains("MutationGuard.shared.isMutating"),
                "REL-06: „Zakończ Wega” must check for a running mutation instead of terminating unconditionally")
    }

    /// `UpgradeMutex` only ever covered `runUpdate` and the background round. A migration
    /// runs `brew install --cask --force` outside it, so it needs its own registration or
    /// ⌘Q still cuts it in half.
    @Test func theMigrationRegistersItsMutation() throws {
        let text = try source("Sources/MacUpdater/MigrationView.swift")
        #expect(text.contains("MutationGuard.shared.begin("),
                "REL-06: a migration is a Caskroom mutation and must be visible to the termination guard")
    }

    /// The gap REL-06 shipped with: `UninstallView` belonged to another branch while the guard
    /// was written, so `uninstall(zap:)` — which runs `brew uninstall --cask`, optionally with
    /// `--zap`, and moves bundles to the Trash — was the one mutation nothing reported. Neither
    /// `UpgradeMutex` (it only covers upgrades) nor a ticket stood behind it, so ⌘Q during an
    /// uninstall still ended the process mid-Caskroom.
    @Test func theUninstallRegistersItsMutation() throws {
        let text = try source("Sources/MacUpdater/UninstallView.swift")
        #expect(text.contains("MutationGuard.shared.begin("),
                "REL-06: an uninstall rewrites the Caskroom and must be visible to the termination guard")
        #expect(text.contains("MutationGuard.shared.end("),
                "REL-06: the uninstall ticket must be released, or the guard blocks every later quit")
    }
}
