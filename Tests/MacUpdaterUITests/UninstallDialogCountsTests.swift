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

    @Test func missingRouteCountsAsTrash() {
        let ok = app("Ok")
        let counts = UninstallDialogCounts(targets: [ok], routes: [:])
        #expect(counts.trash == 1)
        #expect(counts.promisesTrash)
    }
}
