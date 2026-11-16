import XCTest
@testable import MacUpdaterCore

/// UX-13 regression: the "app + leftovers" promise must hold for apps installed outside
/// Homebrew. What the user keeps ticked goes to the Trash — never a permanent `removeItem`
/// (SEC-01). Planning (existence filter, SEC-06 bundle-id check) is pinned by the
/// `LeftoverPlanner` suites.
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

    /// Materialise a subset of a bundle id's `~/Library` leftover locations on disk so the
    /// removal has something real to move. Returns the created URLs.
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

    // MARK: - Removal

    /// The card's core regression: the consented `~/Library` leftovers of a non-brew app
    /// leave for the Trash. The injected trasher stands in for the Trash — it moves items
    /// aside rather than deleting them, mirroring `trashItem`.
    func testNonBrewUninstallMovesLibraryLeftoversToTheTrash() throws {
        let plan = try createLeftovers(bundleID: "com.acme.orphan", keeping: [0, 1, 2, 3, 4])

        let trash = home.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

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
