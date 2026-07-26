import XCTest
@testable import MacUpdaterCore

/// UX-13 regression: the "app + leftovers" promise must hold for apps installed outside
/// Homebrew. Uninstalling a non-brew app has to plan its `~/Library` leftovers through the
/// same builder migration already trusts (`MigrationPlanner`) and move what the user keeps
/// ticked to the Trash — never a permanent `removeItem` (SEC-01), never a path built from
/// an unsafe bundle id (SEC-06).
final class LeftoverCleanupTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ux13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        try super.tearDownWithError()
    }

    /// Materialise a subset of a bundle id's leftover candidates on disk so the plan has
    /// something real to find. Returns the created URLs in the planner's canonical order.
    @discardableResult
    private func createLeftovers(bundleID: String, keeping indices: Set<Int>) throws -> [URL] {
        let candidates = MigrationPlanner.libraryLeftoverCandidates(bundleId: bundleID, home: home)
        var created: [URL] = []
        for (index, url) in candidates.enumerated() where indices.contains(index) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            created.append(url)
        }
        return created
    }

    // MARK: - Planning

    /// The plan reuses `MigrationPlanner` and keeps only the candidates that exist on disk,
    /// in the planner's canonical order.
    func testPlanReusesMigrationPlannerAndKeepsOnlyExistingItems() throws {
        let bundleID = "com.acme.orphan"
        let expected = try createLeftovers(bundleID: bundleID, keeping: [0, 2, 4])

        let plan = LeftoverCleanup.plan(bundleID: bundleID, home: home)

        XCTAssertEqual(plan, expected)
        XCTAssertEqual(
            plan,
            MigrationPlanner.libraryLeftoverCandidates(bundleId: bundleID, home: home)
                .filter { FileManager.default.fileExists(atPath: $0.path) },
            "The plan must be exactly the MigrationPlanner candidates that exist on disk"
        )
    }

    /// A bundle id with no leftovers on disk plans nothing — the sheet stays empty.
    func testPlanIsEmptyWhenNothingIsOnDisk() {
        let plan = LeftoverCleanup.plan(bundleID: "com.acme.ghost", home: home)
        XCTAssertTrue(plan.isEmpty)
    }

    /// SEC-06: an unsafe bundle id yields no deletion paths, so nothing can escape `~/Library`.
    func testPlanRefusesUnsafeBundleID() throws {
        try createLeftovers(bundleID: "com.acme.orphan", keeping: [0, 1, 2, 3, 4])
        XCTAssertTrue(LeftoverCleanup.plan(bundleID: "../../../etc/passwd", home: home).isEmpty)
        XCTAssertTrue(LeftoverCleanup.plan(bundleID: "", home: home).isEmpty)
    }

    // MARK: - Removal

    /// The card's core regression: uninstalling a non-brew app plans and removes its
    /// `~/Library` leftovers through `MigrationPlanner`. The injected trasher stands in for
    /// the Trash — it moves items aside rather than deleting them, mirroring `trashItem`.
    func testNonBrewUninstallPlansAndRemovesLibraryLeftovers() throws {
        let bundleID = "com.acme.orphan"
        let expected = try createLeftovers(bundleID: bundleID, keeping: [0, 1, 2, 3, 4])

        let trash = home.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        let plan = LeftoverCleanup.plan(bundleID: bundleID, home: home)
        XCTAssertEqual(plan, expected)

        let result = LeftoverCleanup.removeToTrash(plan) { url in
            try FileManager.default.moveItem(
                at: url,
                to: trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
            )
        }

        XCTAssertEqual(result.removed, plan)
        XCTAssertTrue(result.failed.isEmpty)
        for url in plan {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) should have left ~/Library for the Trash"
            )
        }
    }

    /// Per-item trash failures are reported, not swallowed into the success count.
    func testRemoveToTrashReportsFailuresWithoutSwallowing() {
        let ok = home.appendingPathComponent("Library/Caches/com.acme.ok", isDirectory: true)
        let boom = home.appendingPathComponent("Library/Caches/com.acme.boom", isDirectory: true)

        struct TrashError: Error {}
        let result = LeftoverCleanup.removeToTrash([ok, boom]) { url in
            if url == boom { throw TrashError() }
        }

        XCTAssertEqual(result.removed, [ok])
        XCTAssertEqual(result.failed, [boom])
    }
}
