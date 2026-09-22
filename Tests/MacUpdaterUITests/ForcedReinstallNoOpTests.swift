import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// „Aktualizuj przez Brew" must detect a no-op the same way an ordinary upgrade does.
///
/// The Discord loop, observed 2026-09-22: `/opt/homebrew/Caskroom/discord/0.0.413` was recorded
/// at 09:01:39 while `/Applications/Discord.app` still reported `0.0.412` — the Obsidian case
/// again, one path over. `brew outdated --greedy` printed nothing (brew believes its own
/// record), every scan read `Info.plist` and kept calling it outdated, and Wega's history
/// recorded `upgraded: true, phase: succeeded` for discord on 09-10, 09-15 and 09-22.
///
/// `CaskRollbackGuard` has carried the check for this since the Obsidian fix, but gated behind
/// `ArrivalEvidence.versionChange`. A manual row backed by a cask updates through
/// `brew install --cask --force`, whose overload hardcodes `.forcedReinstall` — and that turns
/// the check off outright. The reasoning behind the stand-down is sound for a *takeover*, where
/// the cask offers exactly the version already on disk and an unchanged bundle proves nothing.
/// It is wrong for an *update*, where the cask offers a version the disk does not have: there
/// an unchanged bundle is precisely the no-op the check was written for. The switch was keyed
/// on the command rather than on whether the run was supposed to move the version at all.
@Suite("A forced reinstall that changed nothing is not a success")
@MainActor
struct ForcedReinstallNoOpTests {
    private func makeApp(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.hnc.Discord",
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// Everything the guard would otherwise complain about is made to pass, so the verdict can
    /// only be decided by the arrival check: same publisher, same bundle id, Gatekeeper happy,
    /// smoke test off.
    private func permissiveDependencies() -> CaskRollbackGuard.Dependencies {
        CaskRollbackGuard.Dependencies(
            teamIDBeforeMutation: { _ in "TEAM" },
            teamIDAfterMutation: { _ in "TEAM" },
            recordTeamID: { _, teamID in .unchanged(teamID: teamID) },
            applyRollbackLedger: { _, _ in },
            clone: { _, _ in },
            bundleIdentifier: { _ in "com.hnc.Discord" },
            passesGatekeeper: { _ in true },
            restore: { _, _ in },
            helperIsEnabled: { false },
            helperReplace: { _, _ in },
            removeItem: { _ in },
            smokeTestIsEnabled: { false },
            launchSmokeTest: { _ in .survived }
        )
    }

    /// The regression. Red before the fix: the forced-reinstall overload stands the arrival
    /// check down unconditionally, so this returns `.healthy` — which `recordVerdict` stamps
    /// `verified → committed` and the banner announces as „Zaktualizowano".
    @Test func anUpdateThroughBrewThatLeftTheOldBundleIsNotHealthy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forced-reinstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The exact shape on disk after the Discord run: the snapshot is the pre-upgrade
        // bundle, and the app brew claims to have replaced is still that same version.
        let snapshot = root.appendingPathComponent("snapshot/Discord.app", isDirectory: true)
        let installed = root.appendingPathComponent("Applications/Discord.app", isDirectory: true)
        try makeApp(at: snapshot, version: "0.0.412")
        try makeApp(at: installed, version: "0.0.412")

        let verdict = await CaskRollbackGuard.verify(
            token: "discord",
            snapshotURL: snapshot,
            validationURL: installed,
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.hnc.Discord", version: "0.0.413"),
            operation: nil,
            dependencies: permissiveDependencies()
        )

        #expect(verdict == .notUpgraded,
                "the cask offered 0.0.413 and the disk kept 0.0.412 — nothing was installed")
    }

    /// The other half of the same rule, and the reason it cannot simply be switched on for
    /// every forced reinstall: „Przepnij pod Brew" adopts an app that is *already* the version
    /// the cask ships. An unchanged bundle there is the expected outcome of a successful
    /// takeover, not evidence that brew did nothing.
    @Test func aPlainTakeoverIsStillReportedAsTheSuccessItIs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = root.appendingPathComponent("snapshot/Discord.app", isDirectory: true)
        let installed = root.appendingPathComponent("Applications/Discord.app", isDirectory: true)
        try makeApp(at: snapshot, version: "0.0.413")
        try makeApp(at: installed, version: "0.0.413")

        let verdict = await CaskRollbackGuard.verify(
            token: "discord",
            snapshotURL: snapshot,
            validationURL: installed,
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.hnc.Discord", version: nil),
            operation: nil,
            dependencies: permissiveDependencies()
        )

        #expect(verdict == .healthy,
                "a takeover of an already-current app must not be reported as a failed upgrade")
    }
}
