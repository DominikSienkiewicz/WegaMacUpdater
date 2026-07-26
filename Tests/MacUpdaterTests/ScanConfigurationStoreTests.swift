import XCTest
@testable import MacUpdaterCore

/// UX-16 — persistence of the scan configuration in `UserDefaults`. User directories are
/// stored as bookmarks (created with plain options here so the test process needs no
/// entitlement); exclusions as paths; depth as a clamped integer.
final class ScanConfigurationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tmp: URL!

    override func setUpWithError() throws {
        suiteName = "wega.scan.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Recursion depth

    func testRecursionDepthDefaultsWhenUnset() {
        XCTAssertEqual(ScanConfigurationStore.recursionDepth(from: defaults),
                       ScanConfiguration.defaultRecursionDepth)
    }

    func testRecursionDepthPersistsAndClamps() {
        ScanConfigurationStore.setRecursionDepth(3, in: defaults)
        XCTAssertEqual(ScanConfigurationStore.recursionDepth(from: defaults), 3)

        ScanConfigurationStore.setRecursionDepth(-5, in: defaults)
        XCTAssertEqual(ScanConfigurationStore.recursionDepth(from: defaults), 0)

        ScanConfigurationStore.setRecursionDepth(9_999, in: defaults)
        XCTAssertEqual(ScanConfigurationStore.recursionDepth(from: defaults),
                       ScanConfiguration.maximumRecursionDepth)
    }

    // MARK: - Exclusions

    func testExclusionPathsRoundTripAndDeduplicate() {
        let a = tmp.appendingPathComponent("a", isDirectory: true)
        let b = tmp.appendingPathComponent("b", isDirectory: true)

        XCTAssertTrue(ScanConfigurationStore.addExclusion(a, to: defaults))
        XCTAssertTrue(ScanConfigurationStore.addExclusion(b, to: defaults))
        XCTAssertFalse(ScanConfigurationStore.addExclusion(a, to: defaults), "Duplicate exclusion is rejected.")

        XCTAssertEqual(Set(ScanConfigurationStore.exclusionPaths(from: defaults)),
                       Set([a.standardizedFileURL.path, b.standardizedFileURL.path]))

        ScanConfigurationStore.removeExclusion(path: a.standardizedFileURL.path, from: defaults)
        XCTAssertEqual(ScanConfigurationStore.exclusionPaths(from: defaults), [b.standardizedFileURL.path])
    }

    // MARK: - User directories (bookmarks)

    func testUserDirectoryBookmarkRoundTripResolvesToURL() {
        XCTAssertTrue(ScanConfigurationStore.addUserDirectory(tmp, to: defaults, creationOptions: []))

        let resolved = ScanConfigurationStore.resolvedUserDirectories(from: defaults)
        XCTAssertEqual(resolved.map { $0.resolvingSymlinksInPath().path },
                       [tmp.resolvingSymlinksInPath().path])
    }

    func testAddingSameUserDirectoryTwiceIsDeduplicatedByResolvedPath() {
        XCTAssertTrue(ScanConfigurationStore.addUserDirectory(tmp, to: defaults, creationOptions: []))
        XCTAssertFalse(ScanConfigurationStore.addUserDirectory(tmp, to: defaults, creationOptions: []),
                       "The same directory must not be stored twice.")
        XCTAssertEqual(ScanConfigurationStore.resolvedUserDirectories(from: defaults).count, 1)
    }

    func testRemoveUserDirectoryByResolvedPath() {
        ScanConfigurationStore.addUserDirectory(tmp, to: defaults, creationOptions: [])
        ScanConfigurationStore.removeUserDirectory(
            resolvedPath: tmp.resolvingSymlinksInPath().path, from: defaults
        )
        XCTAssertTrue(ScanConfigurationStore.resolvedUserDirectories(from: defaults).isEmpty)
    }

    func testUnresolvableBookmarkIsDroppedNotCrashing() {
        defaults.set([Data([0x00, 0x01, 0x02])], forKey: ScanConfigurationStore.userDirectoryBookmarksKey)
        XCTAssertTrue(ScanConfigurationStore.resolvedUserDirectories(from: defaults).isEmpty)
    }

    // MARK: - Resolved configuration

    func testResolvedConfigurationCombinesAllInputs() {
        ScanConfigurationStore.addUserDirectory(tmp, to: defaults, creationOptions: [])
        let excluded = tmp.appendingPathComponent("skip", isDirectory: true)
        ScanConfigurationStore.addExclusion(excluded, to: defaults)
        ScanConfigurationStore.setRecursionDepth(2, in: defaults)

        let config = ScanConfigurationStore.resolvedConfiguration(from: defaults)
        XCTAssertEqual(config.recursionDepth, 2)
        XCTAssertEqual(config.userDirectories.map { $0.resolvingSymlinksInPath().path },
                       [tmp.resolvingSymlinksInPath().path])
        XCTAssertEqual(config.exclusions.map { $0.standardizedFileURL.path },
                       [excluded.standardizedFileURL.path])
    }

    func testResolvedConfigurationEmptyDefaultsMatchLegacyDefault() {
        let config = ScanConfigurationStore.resolvedConfiguration(from: defaults)
        XCTAssertTrue(config.userDirectories.isEmpty)
        XCTAssertTrue(config.exclusions.isEmpty)
        XCTAssertEqual(config.recursionDepth, ScanConfiguration.defaultRecursionDepth)
    }
}
