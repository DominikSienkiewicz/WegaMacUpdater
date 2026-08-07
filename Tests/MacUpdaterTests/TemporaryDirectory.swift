import Foundation

/// A scratch directory that removes itself when the test that owns it goes away.
///
/// A class rather than a struct so the cleanup rides `deinit` — `swift-testing` has no
/// `tearDown`, and a `defer` in every test that builds a fixture tree is exactly the kind of
/// bookkeeping that gets forgotten and leaves temp directories behind.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func makeSubdirectory(_ name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A JDK bundle shaped like the ones macOS installers lay down: a `.jdk` directory whose
    /// `Contents/Info.plist` carries the release in `CFBundleShortVersionString` and the build
    /// number alone in `CFBundleVersion`.
    @discardableResult
    func makeJDK(
        named name: String,
        shortVersion: String,
        bundleVersion: String? = nil,
        in directory: URL? = nil
    ) throws -> URL {
        var plist: [String: Any] = [
            "CFBundleIdentifier": "net.java.openjdk.jdk",
            "CFBundleName": "OpenJDK \(shortVersion)",
            "CFBundleShortVersionString": shortVersion,
        ]
        if let bundleVersion { plist["CFBundleVersion"] = bundleVersion }
        return try makeBundle(named: name, in: directory ?? url, plist: plist)
    }

    @discardableResult
    func makeApp(
        named name: String,
        bundleIdentifier: String,
        version: String,
        displayName: String? = nil,
        in directory: URL? = nil
    ) throws -> URL {
        try makeBundle(named: "\(name).app", in: directory ?? url, plist: [
            "CFBundleName": displayName ?? name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
        ])
    }

    private func makeBundle(named name: String, in directory: URL, plist: [String: Any]) throws -> URL {
        let bundleURL = directory.appendingPathComponent(name, isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}
