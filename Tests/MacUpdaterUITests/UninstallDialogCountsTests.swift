import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

@Suite("Uninstall dialog counts")
struct UninstallDialogCountsTests {
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

    @Test func blockedTargetsAreNotCountedAsGoingToTheTrash() {
        let ok = app("Ok"), blocked = app("Blocked"), cask = app("Cask", brew: true)
        let counts = UninstallDialogCounts(
            targets: [ok, blocked, cask],
            routes: [ok.id: .userTrash, blocked.id: .blocked(.needsAdministratorRights)]
        )
        #expect(counts.brew == 1)
        #expect(counts.trash == 1)
        #expect(counts.blocked == 1)
    }

    @Test func confirmLabelDoesNotPromiseTheTrashWhenEverythingIsBlocked() {
        let blocked = app("Blocked")
        let counts = UninstallDialogCounts(
            targets: [blocked], routes: [blocked.id: .blocked(.needsAppManagement)]
        )
        #expect(counts.trash == 0)
        #expect(!counts.promisesTrash)
    }

    @Test func everyTargetBlockedRemovesNothing() {
        let first = app("First"), second = app("Second")
        let allBlocked = UninstallDialogCounts(
            targets: [first, second],
            routes: [first.id: .blocked(.needsAdministratorRights), second.id: .blocked(.needsAppManagement)]
        )
        #expect(allBlocked.removesNothing)

        let oneTrashed = UninstallDialogCounts(
            targets: [first, second],
            routes: [first.id: .blocked(.needsAdministratorRights), second.id: .userTrash]
        )
        #expect(!oneTrashed.removesNothing)

        let cask = app("Cask", brew: true)
        let blockedAndCask = UninstallDialogCounts(
            targets: [first, cask], routes: [first.id: .blocked(.needsAdministratorRights)]
        )
        #expect(!blockedAndCask.removesNothing)
    }

    /// A blocked app is not asked to quit, so the sheet must not say it will be.
    @Test func blockedTargetHasNoRunningNote() {
        let target = app("Chrome")
        let running = RunningApplicationResolution.running(RunningApplicationTarget(
            processIdentifier: 10, bundleURL: target.path, bundleIdentifier: target.bundleIdentifier,
            appName: target.name, processName: target.name
        ))
        #expect(UninstallDialog.runningNote(for: running, route: .blocked(.needsAdministratorRights)) == nil)
        #expect(UninstallDialog.runningNote(for: running, route: .userTrash) != nil)
        #expect(UninstallDialog.runningNote(for: running, route: nil) != nil)
    }

    /// Spec 4.3: the sheet says ahead of time that Wega's helper removes a root-owned app, and
    /// that it needs no password.
    @Test func helperRouteSaysWegasHelperRemovesItWithoutAPassword() {
        let note = UninstallDialog.routeNote(for: .helper)

        #expect(note == "pomocnik Wega usunie ją bez hasła")
        #expect(note != UninstallResultPresentation.blockReason(.needsHelper))
    }

    @Test func missingRouteCountsAsTrash() {
        let ok = app("Ok")
        let counts = UninstallDialogCounts(targets: [ok], routes: [:])
        #expect(counts.trash == 1)
        #expect(counts.promisesTrash)
    }
}
