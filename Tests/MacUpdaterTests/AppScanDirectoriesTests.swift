import XCTest
@testable import MacUpdaterCore

/// UX-16 — configurable scan directories, exclusions, controlled recursion depth, and
/// resolved-path deduplication. Exercises `AppScanDirectories.all(configuration:)` end to
/// end through the real `ApplicationScanner`, so a directory that is returned but never
/// scanned would still fail these tests.
final class AppScanDirectoriesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeApp(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appURL = directory.appendingPathComponent("\(name).app")
        let contentsURL = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleIdentifier": "com.test.\(name.lowercased())",
            "CFBundleShortVersionString": "1.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    /// Every `.app` name found by scanning every directory the configuration expands to.
    private func scannedAppNames(_ configuration: ScanConfiguration) -> [String] {
        let scanner = ApplicationScanner()
        return AppScanDirectories.all(configuration: configuration).flatMap { dir in
            (try? scanner.scanApplications(in: dir)) ?? []
        }.map(\.name)
    }

    // MARK: - AC: user directories outside the built-in roots

    func testUserAddedDirectoryOutsideRootsAppearsInScan() throws {
        let custom = root.appendingPathComponent("Custom Volume/Apps", isDirectory: true)
        let appName = "Outsider-\(UUID().uuidString)"
        try makeApp(named: appName, in: custom)

        let config = ScanConfiguration(userDirectories: [custom])

        XCTAssertTrue(
            AppScanDirectories.all(configuration: config).contains { $0.standardizedFileURL == custom.standardizedFileURL },
            "The user-added directory must be part of the scan set."
        )
        XCTAssertTrue(
            scannedAppNames(config).contains(appName),
            "An app in a user-added directory outside /Applications and ~/Applications must appear in the scan result."
        )
    }

    // MARK: - AC: exclusions

    func testExcludedDirectoryIsNotScanned() throws {
        let keptName = "Kept-\(UUID().uuidString)"
        let excludedName = "Hidden-\(UUID().uuidString)"
        try makeApp(named: keptName, in: root)
        let excludedDir = root.appendingPathComponent("Excluded", isDirectory: true)
        try makeApp(named: excludedName, in: excludedDir)

        let config = ScanConfiguration(userDirectories: [root], exclusions: [excludedDir])
        let dirs = AppScanDirectories.all(configuration: config)

        XCTAssertFalse(
            dirs.contains { $0.resolvingSymlinksInPath().path == excludedDir.resolvingSymlinksInPath().path },
            "An excluded directory must never be part of the scan set."
        )
        let names = scannedAppNames(config)
        XCTAssertTrue(names.contains(keptName))
        XCTAssertFalse(names.contains(excludedName), "An app inside an excluded directory must not be scanned.")
    }

    // MARK: - AC: controlled recursion depth

    func testRecursionDepthDescendsExactlyAsConfigured() throws {
        // root/level1/level2/Deep.app — only reachable once depth >= 2.
        let level2 = root.appendingPathComponent("level1/level2", isDirectory: true)
        let deepName = "Deep-\(UUID().uuidString)"
        try makeApp(named: deepName, in: level2)

        let shallow = ScanConfiguration(userDirectories: [root], recursionDepth: 1)
        XCTAssertFalse(scannedAppNames(shallow).contains(deepName),
                       "Depth 1 must not reach a grandchild directory.")

        let deep = ScanConfiguration(userDirectories: [root], recursionDepth: 2)
        XCTAssertTrue(scannedAppNames(deep).contains(deepName),
                      "Depth 2 must reach the grandchild directory.")
    }

    func testDefaultDepthMatchesImmediateChildrenOnly() throws {
        XCTAssertEqual(ScanConfiguration().recursionDepth, 1,
                       "Default depth preserves the legacy 'immediate children' behaviour.")

        let deepName = "TooDeep-\(UUID().uuidString)"
        let grandchild = root.appendingPathComponent("a/b", isDirectory: true)
        try makeApp(named: deepName, in: grandchild)

        XCTAssertFalse(
            scannedAppNames(ScanConfiguration(userDirectories: [root])).contains(deepName),
            "The default configuration must not descend past immediate children."
        )
    }

    // MARK: - AC: resolved-path deduplication (REL-16 interaction)

    func testResolvedPathDeduplicationPreventsSymlinkDoubleScan() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        let dupName = "Doubled-\(UUID().uuidString)"
        try makeApp(named: dupName, in: real)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // The user added both the real directory and a symlink pointing at it.
        let config = ScanConfiguration(userDirectories: [real, link])

        let dirs = AppScanDirectories.all(configuration: config)
        let dedupedToReal = dirs.filter { $0.resolvingSymlinksInPath().path == real.resolvingSymlinksInPath().path }
        XCTAssertEqual(dedupedToReal.count, 1,
                       "A directory and a symlink resolving to it must collapse to a single scan entry.")

        let occurrences = scannedAppNames(config).filter { $0 == dupName }.count
        XCTAssertEqual(occurrences, 1,
                       "A symlink between scan directories must not multiply each app.")
    }
}
