import XCTest
@testable import MacUpdaterCore

final class UpdatePolicyTests: XCTestCase {
    private func item(_ key: String, to: String?) -> OutdatedItem {
        OutdatedItem(key: key, name: key, from: "1.0", to: to, kind: .cask)
    }
    private func manual(_ name: String, available: String?) -> ManualOutdatedApp {
        ManualOutdatedApp(name: name, path: URL(fileURLWithPath: "/Applications/\(name).app"),
                          installedVersion: "1.0", availableVersion: available, source: .parallels)
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
        let apps = [manual("Parallels Desktop", available: "19.1")]
        let policies = ["manual:parallels desktop": UpdatePolicy.pinned(version: "18.0")]
        XCTAssertTrue(UpdatePlanner.applyPolicies(apps, policies: policies).isEmpty)
    }

    func testManualPolicyKeyIsCaseInsensitiveOnName() {
        XCTAssertEqual(manual("Parallels Desktop", available: "1").policyKey, "manual:parallels desktop")
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
