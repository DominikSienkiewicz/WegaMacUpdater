import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

/// Counts how often the injected catalog loader runs.
private actor CatalogLoads {
    private(set) var count = 0

    func record() { count += 1 }
}

/// UX-13: uninstalling a non-brew application must plan its leftovers so the confirm sheet
/// can offer them for the Trash. The removal itself goes through the real Trash (covered by
/// `LeftoverCleanupTests` in Core) and the planning rules by the `LeftoverPlanner` suites;
/// here we pin the coordinator's wiring: it feeds the cask catalog, the other installed apps
/// and the run's other targets to `LeftoverPlanner`, and leaves brew casks to `--zap`.
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

    @discardableResult
    private func createFolder(_ relative: String, in home: URL) throws -> URL {
        let url = home.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func app(
        _ name: String,
        bundleID: String?,
        brew: Bool,
        path: String? = nil
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(filePath: path ?? "/Applications/\(name).app", directoryHint: .isDirectory),
            name: name,
            bundleIdentifier: bundleID,
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: brew ? name.lowercased() : nil
        )
    }

    /// A coordinator whose seams touch nothing but the injected catalog and the temp home.
    private func coordinator(
        catalog: @escaping @Sendable () async -> [BrewCask]? = { [] }
    ) -> UninstallCoordinator {
        UninstallCoordinator(dependencies: .init(
            uninstallCask: { _, _, _ in },
            trashItem: { _ in },
            trashLeftovers: { LeftoverCleanup.Result(removed: $0) },
            protection: { _ in nil },
            runningApplications: { [] },
            requestQuit: { _ in false },
            forceKill: { _ in false },
            waitBetweenRunningChecks: {},
            bundleFacts: { _ in .userOwnedWritable },
            stageForTrash: { _, _ in throw StagingNotExpected() },
            loadCaskCatalog: catalog
        ))
    }

    @Test func scanLeftoversFindsLibraryLeftoversForNonBrewApp() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundleID = "com.example.orphan"
        let expected = try createLeftovers(bundleID: bundleID, home: home)
        let orphan = app("Orphan", bundleID: bundleID, brew: false)

        let scan = await coordinator().scanLeftovers(for: [orphan], installed: [orphan], home: home)

        #expect(scan.groups.count == 1)
        #expect(scan.groups.first?.items.map(\.url.path) == expected.map(\.path))
    }

    @Test func scanLeftoversSkipsBrewApps() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Leftovers exist on disk, but brew casks clean ~/Library via `--zap`.
        _ = try createLeftovers(bundleID: "com.example.brewapp", home: home)
        let brewApp = app("BrewApp", bundleID: "com.example.brewapp", brew: true)

        let scan = await coordinator().scanLeftovers(for: [brewApp], installed: [brewApp], home: home)

        #expect(scan.groups.isEmpty)
    }

    @Test func scanLeftoversSkipsAppsWithoutBundleIdentifierOrLeftovers() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let targets = [
            app("NoBundle", bundleID: nil, brew: false),
            app("NothingOnDisk", bundleID: "com.example.clean", brew: false),
        ]

        let scan = await coordinator().scanLeftovers(for: targets, installed: targets, home: home)

        #expect(scan.groups.isEmpty)
    }

    @Test func catalogFailureIsReported() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let orphan = app("Orphan", bundleID: "com.example.orphan", brew: false)

        let scan = await coordinator(catalog: { nil }).scanLeftovers(for: [orphan], installed: [orphan], home: home)

        #expect(scan.catalogUnavailable)
    }

    @Test func noCatalogLoadForBrewOnlyTargets() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let loads = CatalogLoads()
        let brewApp = app("BrewApp", bundleID: "com.example.brewapp", brew: true)
        let sut = coordinator(catalog: {
            await loads.record()
            return nil
        })

        let scan = await sut.scanLeftovers(for: [brewApp], installed: [brewApp], home: home)

        #expect(await loads.count == 0)
        #expect(scan == LeftoverScan(groups: [], catalogUnavailable: false))
    }

    @Test func zapEvidenceReachesThePlanner() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try createFolder("Library/Application Support/obsidian", in: home)
        let obsidian = app("Obsidian", bundleID: "md.obsidian", brew: false)
        let cask = BrewCask(token: "obsidian", name: ["Obsidian"], zapTrashPaths: [
            "~/Library/Application Support/obsidian",
            "~/Library/Preferences/md.obsidian.plist",
        ])

        let scan = await coordinator(catalog: { [cask] })
            .scanLeftovers(for: [obsidian], installed: [obsidian], home: home)

        #expect(!scan.catalogUnavailable)
        #expect(scan.groups.first?.items.map(\.source) == [.homebrewZap(token: "obsidian")])
    }

    /// A target whose route is blocked is not attempted, so the sheet passes it in `installed`
    /// only: it stays installed, and the items it shares with an attempted copy are shared.
    @Test func blockedTargetCountsAsInstalled() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try createFolder("Library/Application Support/com.example.twin", in: home)
        let attempted = app("Twin", bundleID: "com.example.twin", brew: false)
        let blocked = app("Twin", bundleID: "com.example.twin", brew: false, path: "/Users/Shared/Twin.app")

        let scan = await coordinator().scanLeftovers(for: [attempted], installed: [attempted, blocked], home: home)

        let item = try #require(scan.groups.first?.items.first)
        #expect(item.sharedWith.count == 1)
        #expect(item.coTargets.isEmpty)
    }

    /// B plans the folder by its name but does not claim it (A's item comes from A's zap list),
    /// so only "planned the same key" can put B into the item's `coTargets`.
    @Test func laterTargetThatPlannedTheSameKeyIsACoTarget() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try createFolder("Library/Application Support/Vendor", in: home)
        let alpha = app("Vendor Alpha", bundleID: "com.vendor.a", brew: false)
        let vendor = app("Vendor", bundleID: "com.vendor.b", brew: false)
        let cask = BrewCask(token: "vendor-alpha", name: ["Vendor Alpha"], zapTrashPaths: [
            "~/Library/Application Support/Vendor",
            "~/Library/Preferences/com.vendor.a.plist",
        ])

        let scan = await coordinator(catalog: { [cask] })
            .scanLeftovers(for: [alpha, vendor], installed: [alpha, vendor], home: home)

        #expect(scan.groups.map(\.app.id) == [alpha.id])
        let items = try #require(scan.groups.first?.items)
        #expect(items.count == 1)
        #expect(items.first?.source == .homebrewZap(token: "vendor-alpha"))
        #expect(items.first?.coTargets == [vendor.id])
        #expect(items.first?.sharedWith == [])
    }

    @Test func measureLeftoverMeasuresTheItem() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = try createFolder("Library/Caches/com.example.orphan", in: home)
        try Data(repeating: 0x2A, count: 10_000)
            .write(to: folder.appending(component: "cache.db", directoryHint: .notDirectory))

        let size = await coordinator().measureLeftover(folder, home: home)

        guard case .bytes(let bytes) = size else {
            Issue.record("expected a measured size, got \(size)")
            return
        }
        #expect(bytes >= 10_000)
    }
}
