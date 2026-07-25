import XCTest
@testable import MacUpdaterCore

/// REL-16 — an installation is identified by its standardized path, not by its
/// bundle identifier. Two copies of the same application in two locations are two
/// installations, and a destructive operation must reach exactly the one the user
/// ticked.
final class InstallationInventoryTests: XCTestCase {
    private func app(_ path: String, name: String = "Firefox", bundleId: String? = "org.mozilla.firefox") -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path),
            name: name,
            bundleIdentifier: bundleId,
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }

    // MARK: identity

    func testInstallationIdentityIsTheStandardizedPath() {
        let messy = app("/Applications/Utilities/../Firefox.app")
        let plain = app("/Applications/Firefox.app")
        XCTAssertEqual(messy.id, plain.id)
        XCTAssertEqual(plain.id, "/Applications/Firefox.app")
    }

    func testInstallationIdentityIgnoresTrailingSlashAndPrivatePrefix() {
        XCTAssertEqual(app("/Applications/Firefox.app/").id, app("/Applications/Firefox.app").id)
        XCTAssertEqual(app("/private/var/apps/Firefox.app").id, app("/var/apps/Firefox.app").id)
    }

    func testInstallationIdentityKeepsDistinctLocationsDistinct() {
        XCTAssertNotEqual(app("/Applications/Firefox.app").id, app("/Users/x/Applications/Firefox.app").id)
    }

    // MARK: deduplication

    func testTwoCopiesOfTheSameAppStayVisibleSeparately() {
        let system = app("/Applications/Firefox.app")
        let user   = app("/Users/x/Applications/Firefox.app")

        let result = InstallationInventory.deduplicated([system, user])

        XCTAssertEqual(result.map(\.id), [system.id, user.id])
    }

    func testSameInstallationReportedTwiceCollapses() {
        let once  = app("/Applications/Firefox.app")
        let again = app("/Applications/./Firefox.app")

        XCTAssertEqual(InstallationInventory.deduplicated([once, again]).count, 1)
    }

    func testAppsWithoutBundleIdentifierAreStillIdentifiedByPath() {
        let a = app("/Applications/A.app", name: "A", bundleId: nil)
        let b = app("/Applications/B.app", name: "B", bundleId: nil)

        XCTAssertEqual(InstallationInventory.deduplicated([a, b]).count, 2)
    }

    // MARK: bundle id as a grouping key only

    func testBundleIdentifierGroupsInstallationsInsteadOfHidingThem() {
        let system = app("/Applications/Firefox.app")
        let user   = app("/Users/x/Applications/Firefox.app")
        let other  = app("/Applications/Slack.app", name: "Slack", bundleId: "com.tinyspeck.slackmacgap")

        let groups = InstallationInventory.groupedByBundleIdentifier([system, user, other])

        XCTAssertEqual(groups["org.mozilla.firefox"]?.map(\.id), [system.id, user.id])
        XCTAssertEqual(groups["com.tinyspeck.slackmacgap"]?.map(\.id), [other.id])
    }

    func testAmbiguousBundleIdentifiersAreTheOnesInstalledMoreThanOnce() {
        let system = app("/Applications/Firefox.app")
        let user   = app("/Users/x/Applications/Firefox.app")
        let other  = app("/Applications/Slack.app", name: "Slack", bundleId: "com.tinyspeck.slackmacgap")
        let noId   = app("/Applications/Odd.app", name: "Odd", bundleId: nil)

        let ambiguous = InstallationInventory.ambiguousBundleIdentifiers([system, user, other, noId])

        XCTAssertEqual(ambiguous, ["org.mozilla.firefox"])
    }

    func testLocationLabelNamesTheFolderTheCopyLivesIn() {
        XCTAssertEqual(app("/Applications/Firefox.app").locationLabel, "/Applications")
        XCTAssertEqual(app("/Applications/JetBrains/Fleet.app").locationLabel, "/Applications/JetBrains")
    }

    // MARK: destructive operations hit the copy the user picked

    func testSelectionReachesOnlyThePickedCopy() {
        let system = app("/Applications/Firefox.app")
        let user   = app("/Users/x/Applications/Firefox.app")
        let apps   = InstallationInventory.deduplicated([system, user])

        let targets = InstallationInventory.selected(apps, identities: [user.id])

        XCTAssertEqual(targets.map(\.path.path), ["/Users/x/Applications/Firefox.app"])
    }
}
