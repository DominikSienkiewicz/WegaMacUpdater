import XCTest
@testable import MacUpdaterCore

final class UpdatePolicyTests: XCTestCase {
    private func item(_ key: String, to: String?) -> OutdatedItem {
        OutdatedItem(key: key, name: key, from: "1.0", to: to, kind: .cask)
    }
    private func manual(_ name: String, available: String?, bundleIdentifier: String? = nil, path: String? = nil) -> ManualOutdatedApp {
        ManualOutdatedApp(name: name, path: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
                          installedVersion: "1.0", availableVersion: available, source: .parallels,
                          bundleIdentifier: bundleIdentifier)
    }

    // MARK: ignore

    func testIgnoredItemIsSuppressed() {
        let policies = ["c:zoom": UpdatePolicy.ignored]
        XCTAssertTrue(UpdatePlanner.isSuppressed(key: "c:zoom", availableVersion: "6.1", policies: policies))
    }

    func testUnlistedItemIsNotSuppressed() {
        XCTAssertFalse(UpdatePlanner.isSuppressed(key: "c:firefox", availableVersion: "121", policies: ["c:zoom": .ignored]))
    }

    func testApplyPoliciesDropsIgnoredOutdatedItems() {
        let items = [item("c:zoom", to: "6.1"), item("c:firefox", to: "121")]
        let visible = UpdatePlanner.applyPolicies(items, policies: ["c:zoom": .ignored])
        XCTAssertEqual(visible.map(\.key), ["c:firefox"])
    }

    func testEmptyPoliciesReturnsEverything() {
        let items = [item("c:zoom", to: "6.1")]
        XCTAssertEqual(UpdatePlanner.applyPolicies(items, policies: [:]).count, 1)
    }

    // MARK: pin (version ceiling)

    func testPinHidesUpdatesBeyondPinnedVersion() {
        let policies = ["manual:parallels desktop": UpdatePolicy.pinned(version: "18.0")]
        // 19.1 is beyond the pin → hidden
        XCTAssertTrue(UpdatePlanner.isSuppressed(key: "manual:parallels desktop", availableVersion: "19.1", policies: policies))
    }

    func testPinAllowsUpdatesUpToPinnedVersion() {
        let policies = ["manual:parallels desktop": UpdatePolicy.pinned(version: "18.5")]
        // 18.3 is at/below the pin → still shown
        XCTAssertFalse(UpdatePlanner.isSuppressed(key: "manual:parallels desktop", availableVersion: "18.3", policies: policies))
    }

    func testPinToCurrentVersionHoldsInPlace() {
        let policies = ["manual:parallels desktop": UpdatePolicy.pinned(version: "18.0")]
        XCTAssertTrue(UpdatePlanner.isSuppressed(key: "manual:parallels desktop", availableVersion: "18.1", policies: policies))
    }

    func testApplyPoliciesFiltersManualByPin() {
        let app = manual("Parallels Desktop", available: "19.1", bundleIdentifier: "com.parallels.desktop.console")
        let policies = [app.policyKey: UpdatePolicy.pinned(version: "18.0")]
        XCTAssertTrue(UpdatePlanner.applyPolicies([app], policies: policies).isEmpty)
    }

    // MARK: REL-11 — manual policies keyed by bundle ID + install path, not display name

    /// The key is the stable installation identity (`bundle ID + path`), not the
    /// display name — so it survives the vendor renaming the app across versions.
    func testManualPolicyKeyUsesBundleIDAndPath() {
        let app = manual("Zoom", available: "2", bundleIdentifier: "us.zoom.xos",
                         path: "/Applications/zoom.us.app")
        XCTAssertEqual(app.policyKey, "manual:us.zoom.xos|/Applications/zoom.us.app")
    }

    /// Regression for the card's verification step: a pin/ignore assigned before a
    /// display-name change must still match afterwards (same bundle ID + path).
    func testManualPolicyKeySurvivesDisplayNameChange() {
        let before = manual("Parallels Desktop", available: "19.0",
                            bundleIdentifier: "com.parallels.desktop.console",
                            path: "/Applications/Parallels Desktop.app")
        let after = manual("Parallels Desktop 19", available: "19.0",
                           bundleIdentifier: "com.parallels.desktop.console",
                           path: "/Applications/Parallels Desktop.app")
        XCTAssertEqual(before.policyKey, after.policyKey)
    }

    /// Two copies of the same app (same bundle ID, different install path) are
    /// distinct policy targets — pinning one must not silence the other.
    func testManualPolicyKeyDistinguishesCopiesByPath() {
        let system = manual("Firefox", available: "2", bundleIdentifier: "org.mozilla.firefox",
                            path: "/Applications/Firefox.app")
        let user = manual("Firefox", available: "2", bundleIdentifier: "org.mozilla.firefox",
                          path: "\(NSHomeDirectory())/Applications/Firefox.app")
        XCTAssertNotEqual(system.policyKey, user.policyKey)
    }

    // MARK: skip (single version — "skip X, show X+1")

    func testSkippedVersionIsSuppressedForThatVersion() {
        let policies = ["c:zoom": UpdatePolicy.skipped(version: "6.1")]
        XCTAssertTrue(UpdatePlanner.isSuppressed(key: "c:zoom", availableVersion: "6.1", policies: policies))
    }

    func testSkippedVersionResurfacesForNextVersion() {
        let policies = ["c:zoom": UpdatePolicy.skipped(version: "6.1")]
        XCTAssertFalse(UpdatePlanner.isSuppressed(key: "c:zoom", availableVersion: "6.2", policies: policies))
    }

    func testSkippedVersionMatchesNormalizedVariant() {
        // "7.0.0 (77593)" and "7.0.0.77593" are the same version in different formats;
        // a skip stored in one must still hide the other when the next scan reports it.
        let policies = ["c:app": UpdatePolicy.skipped(version: "7.0.0 (77593)")]
        XCTAssertTrue(UpdatePlanner.isSuppressed(key: "c:app", availableVersion: "7.0.0.77593", policies: policies))
    }

    func testSkippedWithoutAvailableVersionIsNotSuppressed() {
        // Skip is deliberately narrow: with no version to match, show the item rather
        // than over-hide it (unlike a pin, which conservatively holds).
        let policies = ["c:app": UpdatePolicy.skipped(version: "6.1")]
        XCTAssertFalse(UpdatePlanner.isSuppressed(key: "c:app", availableVersion: nil, policies: policies))
    }

    /// The card's regression check: a `.skipped` item disappears for the skipped
    /// version and comes back for the next release.
    func testApplyPoliciesHidesSkippedVersionButShowsNext() {
        let policies = ["c:zoom": UpdatePolicy.skipped(version: "6.1")]
        XCTAssertTrue(UpdatePlanner.applyPolicies([item("c:zoom", to: "6.1")], policies: policies).isEmpty)
        XCTAssertEqual(
            UpdatePlanner.applyPolicies([item("c:zoom", to: "6.2")], policies: policies).map(\.key),
            ["c:zoom"]
        )
    }

    func testSkippedPolicyEntryCodableRoundTrip() throws {
        let entries = [UpdatePolicyEntry(key: "c:zoom", displayName: "Zoom", policy: .skipped(version: "6.1"))]
        let data = try JSONEncoder().encode(entries)
        XCTAssertEqual(try JSONDecoder().decode([UpdatePolicyEntry].self, from: data), entries)
    }

    // MARK: round-trips through Codable (persistence relies on it)

    func testPolicyEntryCodableRoundTrip() throws {
        let entries = [
            UpdatePolicyEntry(key: "c:zoom", displayName: "Zoom", policy: .ignored),
            UpdatePolicyEntry(key: "manual:parallels desktop", displayName: "Parallels Desktop", policy: .pinned(version: "18.0")),
        ]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([UpdatePolicyEntry].self, from: data)
        XCTAssertEqual(decoded, entries)
    }
}
