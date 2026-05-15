import XCTest
@testable import MacUpdaterCore

final class HelperPathValidatorTests: XCTestCase {
    func testAllowsDirectApplicationBundleWithExpectedBundleIdentifier() throws {
        let root = try temporaryDirectory()
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let app = applications.appendingPathComponent("Example.app", isDirectory: true)
        try createBundle(at: app, bundleIdentifier: "com.example.App")

        let policy = HelperPathPolicy(applicationsDirectory: applications, homeDirectory: root)

        let validated = try policy.validateRemovalPath(app, expectedBundleIdentifier: "com.example.App")

        XCTAssertEqual(validated.kind, .applicationBundle)
        XCTAssertEqual(validated.url.lastPathComponent, "Example.app")
    }

    func testRejectsApplicationBundleWithWrongBundleIdentifier() throws {
        let root = try temporaryDirectory()
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let app = applications.appendingPathComponent("Example.app", isDirectory: true)
        try createBundle(at: app, bundleIdentifier: "com.example.App")

        let policy = HelperPathPolicy(applicationsDirectory: applications, homeDirectory: root)

        XCTAssertThrowsError(try policy.validateRemovalPath(app, expectedBundleIdentifier: "com.example.Other")) { error in
            XCTAssertEqual(
                error as? HelperPathValidationError,
                .bundleIdentifierMismatch(expected: "com.example.Other", actual: "com.example.App")
            )
        }
    }

    func testAllowsOnlyDirectUserLibraryCleanupPaths() throws {
        let root = try temporaryDirectory()
        let support = root.appendingPathComponent("Library/Application Support/Example", isDirectory: true)
        let cache = root.appendingPathComponent("Library/Caches/com.example.App", isDirectory: true)
        let preference = root.appendingPathComponent("Library/Preferences/com.example.App.plist")

        let policy = HelperPathPolicy(
            applicationsDirectory: root.appendingPathComponent("Applications", isDirectory: true),
            homeDirectory: root
        )

        XCTAssertEqual(try policy.validateRemovalPath(support).kind, .applicationSupport)
        XCTAssertEqual(try policy.validateRemovalPath(cache).kind, .cache)
        XCTAssertEqual(try policy.validateRemovalPath(preference).kind, .preferencePlist)
    }

    func testRejectsNestedUserLibraryCleanupPath() throws {
        let root = try temporaryDirectory()
        let nested = root.appendingPathComponent("Library/Caches/com.example.App/Nested", isDirectory: true)
        let policy = HelperPathPolicy(
            applicationsDirectory: root.appendingPathComponent("Applications", isDirectory: true),
            homeDirectory: root
        )

        XCTAssertThrowsError(try policy.validateRemovalPath(nested))
    }

    func testRejectsSymlinkTraversalOutOfAllowlist() throws {
        let root = try temporaryDirectory()
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        let outside = try temporaryDirectory().appendingPathComponent("Outside")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)

        let symlink = caches.appendingPathComponent("com.example.App")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let policy = HelperPathPolicy(
            applicationsDirectory: root.appendingPathComponent("Applications", isDirectory: true),
            homeDirectory: root
        )

        XCTAssertThrowsError(try policy.validateRemovalPath(symlink))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createBundle(at url: URL, bundleIdentifier: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Example",
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: plist)
    }
}
