import XCTest
@testable import MacUpdaterCore

final class InventoryFootprintTests: XCTestCase {
    func testInventoryOffersDiskUsageAsASortColumn() throws {
        let key = try XCTUnwrap(InventorySortKey(rawValue: "diskUsage"), "The Inventory must offer a disk usage sort column.")
        XCTAssertFalse(key.initiallyAscending, "The first click must show the largest apps first.")
    }
}

@MainActor
extension InventoryFootprintTests {
    private func app(_ path: URL, _ id: String?) -> ApplicationInfo {
        ApplicationInfo(path: path, name: path.deletingPathExtension().lastPathComponent, bundleIdentifier: id,
                        version: nil, installDate: nil, updateDate: nil, isManagedByBrew: false)
    }

    func testSortUsesMeasuredBundleCacheAndSupportAndAlwaysPlacesUnknownLast() async throws {
        let home = try CleanupTempHome()
        let alpha = app(try home.directory("Applications/Alpha.app"), "test.alpha")
        let beta = app(try home.directory("Applications/Beta.app"), "test.beta")
        let charlie = app(try home.directory("Applications/Charlie.app"), "test.charlie")
        let unknown = app(home.url("Applications/Absent.app"), "test.missing")
        try home.file("Applications/Alpha.app/executable", size: 4096)
        try home.file("Library/Caches/test.beta/cache", size: 65536)
        try home.file("Library/Application Support/test.beta/settings", size: 8192)
        try home.file("Library/Application Support/Beta/unrelated", size: 262144)
        try home.file("Library/Containers/test.beta/private", size: 262144)
        let apps = [unknown, charlie, alpha, beta]
        let sizes = try await InventoryFootprintReader(home: home.home).measure(apps)
        let fileSystem = LiveCleanupFileSystem()
        let footprint = try XCTUnwrap(sizes[beta.installation])
        XCTAssertEqual(footprint.cacheBytes, try fileSystem.allocatedSize(of: home.url("Library/Caches/test.beta")))
        XCTAssertEqual(footprint.dataBytes, try fileSystem.allocatedSize(of: home.url("Library/Application Support/test.beta")))
        XCTAssertEqual(sizes[alpha.installation]?.cacheBytes, 0)
        XCTAssertNil(sizes[unknown.installation]?.totalBytes)
        XCTAssertEqual(InventorySort.sorted(apps, by: .diskUsage, ascending: false, footprints: sizes).map(\.name),
                       ["Beta", "Alpha", "Charlie", "Absent"])
        XCTAssertEqual(InventorySort.sorted(apps, by: .diskUsage, ascending: true, footprints: sizes).map(\.name),
                       ["Charlie", "Alpha", "Beta", "Absent"])
    }

    func testSharedOrUnsafeIdentifiersMeasureOnlyTheIndividualBundle() async throws {
        let home = try CleanupTempHome()
        let apps = try [("First", "test.duplicate"), ("Second", "TEST.duplicate"), ("Dots", "."), ("Escape", "../foo")].map { name, id in
            app(try home.directory("Applications/\(name).app"), id)
        }
        try home.file("Library/Application Support/test.duplicate/settings", size: 4096)
        let sizes = try await InventoryFootprintReader(home: home.home).measure(apps)
        for app in apps {
            let size = try XCTUnwrap(sizes[app.installation])
            XCTAssertFalse(size.includesLibrary)
            XCTAssertNil(size.dataBytes)
            XCTAssertEqual(size.totalBytes, size.bundleBytes)
            XCTAssertNotNil(size.totalBytes)
        }
        let tied = InventorySort.sorted(apps.reversed(), by: .diskUsage, ascending: false, footprints: sizes)
        XCTAssertEqual(tied.map(\.installation), apps.map(\.installation).sorted())
    }

    func testUnmeasurableLibraryDoesNotTurnIntoZeroOrFollowSymlinks() async throws {
        let home = try CleanupTempHome()
        let app = app(try home.directory("Applications/Test.app"), "test.app")
        try home.file("Documents/cache/protected", size: 16384)
        try home.symlink("Library/Caches/test.app", to: home.url("Documents/cache").path)
        let sizes = try await InventoryFootprintReader(home: home.home).measure([app])
        let result = try XCTUnwrap(sizes[app.installation])
        XCTAssertTrue(result.includesLibrary)
        XCTAssertNil(result.cacheBytes)
        XCTAssertNil(result.totalBytes)
        XCTAssertNotNil(result.bundleBytes)
    }
}
