import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

/// UX-13: uninstalling a non-brew application must plan its `~/Library` leftovers so the
/// confirm sheet can offer them for the Trash. The removal itself goes through the real
/// Trash (covered by `LeftoverCleanupTests` in Core); here we pin the coordinator's
/// planning: it reuses `MigrationPlanner` for apps outside Homebrew and leaves brew casks
/// to `--zap`.
@MainActor
@Suite("UX-13 leftover uninstall")
struct UX13LeftoverUninstallTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ux13-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func createLeftovers(bundleID: String, home: URL) throws -> [URL] {
        let candidates = MigrationPlanner.libraryLeftoverCandidates(bundleId: bundleID, home: home)
        for url in candidates {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return candidates
    }

    private func app(
        _ name: String,
        bundleID: String?,
        brew: Bool
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: bundleID,
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: brew ? name.lowercased() : nil
        )
    }

    @Test func scanLeftoversFindsLibraryLeftoversForNonBrewApp() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundleID = "com.example.orphan"
        let expected = try createLeftovers(bundleID: bundleID, home: home)

        let coordinator = UninstallCoordinator()
        let groups = await coordinator.scanLeftovers(
            for: [app("Orphan", bundleID: bundleID, brew: false)],
            home: home
        )

        #expect(groups.count == 1)
        #expect(groups.first?.items == expected)
    }

    @Test func scanLeftoversSkipsBrewApps() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Leftovers exist on disk, but brew casks clean ~/Library via `--zap`.
        _ = try createLeftovers(bundleID: "com.example.brewapp", home: home)

        let coordinator = UninstallCoordinator()
        let groups = await coordinator.scanLeftovers(
            for: [app("BrewApp", bundleID: "com.example.brewapp", brew: true)],
            home: home
        )

        #expect(groups.isEmpty)
    }

    @Test func scanLeftoversSkipsAppsWithoutBundleIdentifierOrLeftovers() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let coordinator = UninstallCoordinator()
        let groups = await coordinator.scanLeftovers(
            for: [
                app("NoBundle", bundleID: nil, brew: false),
                app("NothingOnDisk", bundleID: "com.example.clean", brew: false),
            ],
            home: home
        )

        #expect(groups.isEmpty)
    }
}
