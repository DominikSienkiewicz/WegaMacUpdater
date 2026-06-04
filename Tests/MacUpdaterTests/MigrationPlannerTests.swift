import XCTest
@testable import MacUpdaterCore

final class MigrationPlannerTests: XCTestCase {
    private func app(
        _ name: String,
        caskToken: String? = nil,
        brew: Bool = false,
        mas: Bool = false
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: caskToken,
            isManagedByMas: mas
        )
    }

    // MARK: matchable / unmatched

    func testMatchableNeedsCaskTokenAndNotYetMigrated() {
        let candidates = [
            app("Firefox", caskToken: "firefox"),
            app("Migrated", caskToken: "migrated"),
            app("NoCask", caskToken: nil),
        ]
        let result = MigrationPlanner.matchable(candidates: candidates, migrated: ["migrated"])
        XCTAssertEqual(result.map(\.name), ["Firefox"])
    }

    func testUnmatchedExcludesCaskAndAppStoreCandidates() {
        let store = app("Slack")
        let candidates = [
            app("Firefox", caskToken: "firefox"),   // has cask → excluded
            store,                                    // in masAppIDs → excluded
            app("Orphan", caskToken: nil),            // truly unmatched
        ]
        let result = MigrationPlanner.unmatched(candidates: candidates, masAppIDs: [store.id])
        XCTAssertEqual(result.map(\.name), ["Orphan"])
    }

    // MARK: migrationPool

    func testMigrationPoolExcludesBrewAndMasManaged() {
        let pool = MigrationPlanner.migrationPool([
            app("Manual", caskToken: "manual"),
            app("BrewManaged", caskToken: "brewmanaged", brew: true),
            app("MasManaged", mas: true),
        ])
        XCTAssertEqual(pool.map(\.name), ["Manual"])
    }

    // MARK: library leftovers

    func testLibraryLeftoverCandidatesBuildsExpectedPaths() {
        let home = URL(fileURLWithPath: "/Users/test")
        let urls = MigrationPlanner.libraryLeftoverCandidates(bundleId: "com.acme.app", home: home)
        XCTAssertEqual(urls.map(\.path), [
            "/Users/test/Library/Application Support/com.acme.app",
            "/Users/test/Library/Preferences/com.acme.app.plist",
            "/Users/test/Library/Caches/com.acme.app",
            "/Users/test/Library/Saved Application State/com.acme.app.savedState",
            "/Users/test/Library/Containers/com.acme.app",
        ])
    }

    // MARK: DuplicateRemoval

    func testDuplicateRemovalNpmSide() {
        let removal = DuplicateRemoval(dup: NpmBrewDuplicate(npmPackage: "@openai/codex", brewToken: "codex"), side: .npm)
        XCTAssertEqual(removal.busyKey, "npm:@openai/codex")
        XCTAssertEqual(removal.commandPreview, "npm uninstall -g @openai/codex")
        XCTAssertEqual(removal.id, "npm:@openai/codex")
    }

    func testDuplicateRemovalBrewSide() {
        let removal = DuplicateRemoval(dup: NpmBrewDuplicate(npmPackage: "@openai/codex", brewToken: "codex"), side: .brew)
        XCTAssertEqual(removal.busyKey, "brew:codex")
        XCTAssertEqual(removal.commandPreview, "brew uninstall codex")
    }
}
