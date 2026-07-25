import XCTest
@testable import MacUpdaterCore

/// REL-16 — `sort(by:)` requires a strict weak ordering. Descending order built as
/// `!ascending` returns `true` for both `(a, b)` and `(b, a)` whenever the two
/// elements compare equal, which breaks that contract.
final class InventorySortTests: XCTestCase {
    private func app(
        _ name: String,
        path: String? = nil,
        version: String? = "1.0",
        bundleId: String? = "com.example.app",
        updateDate: Date? = nil,
        brew: Bool = false,
        mas: Bool = false
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: bundleId,
            version: version,
            installDate: nil,
            updateDate: updateDate,
            isManagedByBrew: brew,
            isManagedByMas: mas
        )
    }

    /// Every pair of equal elements, in every sort direction, on every key.
    private func assertStrictOrdering(
        _ a: ApplicationInfo,
        _ b: ApplicationInfo,
        key: InventorySortKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for ascending in [true, false] {
            let cmp = InventorySort.comparator(key: key, ascending: ascending)
            XCTAssertFalse(
                cmp(a, b) && cmp(b, a),
                "\(key) (ascending: \(ascending)): both cmp(a,b) and cmp(b,a) are true — not a strict weak ordering",
                file: file, line: line
            )
            XCTAssertFalse(cmp(a, a), "\(key): comparator is not irreflexive", file: file, line: line)
        }
    }

    func testDescendingComparatorIsStrictForEqualNames() {
        let a = app("Same", path: "/Applications/A.app")
        let b = app("Same", path: "/Applications/B.app")
        assertStrictOrdering(a, b, key: .name)
    }

    func testDescendingComparatorIsStrictForEqualVersionsAndBundleIds() {
        let a = app("A", path: "/Applications/A.app", version: "1.0", bundleId: "com.example.x")
        let b = app("B", path: "/Applications/B.app", version: "1.0", bundleId: "com.example.x")
        assertStrictOrdering(a, b, key: .version)
        assertStrictOrdering(a, b, key: .bundleId)
    }

    func testDescendingComparatorIsStrictForEqualSourceAndUpdateDate() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let a = app("A", path: "/Applications/A.app", updateDate: stamp, brew: true)
        let b = app("B", path: "/Applications/B.app", updateDate: stamp, brew: true)
        assertStrictOrdering(a, b, key: .source)
        assertStrictOrdering(a, b, key: .updateDate)
    }

    func testDescendingComparatorIsStrictForMissingVersionsAndBundleIds() {
        let a = app("A", path: "/Applications/A.app", version: nil, bundleId: nil)
        let b = app("B", path: "/Applications/B.app", version: nil, bundleId: nil)
        assertStrictOrdering(a, b, key: .version)
        assertStrictOrdering(a, b, key: .bundleId)
    }

    // MARK: the ordering itself still does what the column headers promise

    func testAscendingAndDescendingByName() {
        let apps = [app("Charlie"), app("Alpha"), app("Bravo")]
        XCTAssertEqual(InventorySort.sorted(apps, by: .name, ascending: true).map(\.name), ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(InventorySort.sorted(apps, by: .name, ascending: false).map(\.name), ["Charlie", "Bravo", "Alpha"])
    }

    func testSourceOrdersBrewThenAppStoreThenManual() {
        let apps = [app("Manual"), app("Store", mas: true), app("Brewed", brew: true)]
        XCTAssertEqual(
            InventorySort.sorted(apps, by: .source, ascending: true).map(\.name),
            ["Brewed", "Store", "Manual"]
        )
    }

    func testEqualElementsKeepADeterministicOrderInBothDirections() {
        let a = app("Same", path: "/Applications/A.app")
        let b = app("Same", path: "/Applications/B.app")
        XCTAssertEqual(InventorySort.sorted([b, a], by: .name, ascending: true).map(\.id),
                       InventorySort.sorted([a, b], by: .name, ascending: true).map(\.id))
        XCTAssertEqual(InventorySort.sorted([b, a], by: .name, ascending: false).map(\.id),
                       InventorySort.sorted([a, b], by: .name, ascending: false).map(\.id))
    }
}
