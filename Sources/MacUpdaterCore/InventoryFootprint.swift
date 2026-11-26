import Foundation

public struct InventoryFootprint: Equatable, Sendable {
    public let bundleBytes: Int64?
    public let cacheBytes: Int64?
    public let dataBytes: Int64?
    public let includesLibrary: Bool

    public var totalBytes: Int64? {
        guard includesLibrary else { return bundleBytes }
        guard let bundleBytes, let cacheBytes, let dataBytes else { return nil }
        return bundleBytes + cacheBytes + dataBytes
    }
}

/// Measures allocated space on demand. The Library portion covers only per-user Caches and
/// Application Support directories named for a single installation's exact bundle identifier.
public actor InventoryFootprintReader {
    private let library: URL
    private let fileSystem: GuardedCleanupFileSystem

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        library = home.appending(component: "Library", directoryHint: .isDirectory)
        fileSystem = GuardedCleanupFileSystem(base: LiveCleanupFileSystem(), guard: ProtectedLocationGuard(home: home, mounts: LiveMountTable()))
    }

    public func measure(_ apps: [ApplicationInfo]) throws -> [InstallationIdentity: InventoryFootprint] {
        let identifierCounts = apps.compactMap { $0.bundleIdentifier?.lowercased() }
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var result: [InstallationIdentity: InventoryFootprint] = [:]
        for app in apps {
            try Task.checkCancellation()
            let bundle = directoryBytes(at: app.path, missing: nil)
            let id = app.bundleIdentifier
            if let id, MigrationPlanner.isSafeBundleID(id), id.contains("."), !id.hasPrefix("."), !id.hasSuffix("."),
               identifierCounts[id.lowercased()] == 1 {
                result[app.installation] = InventoryFootprint(
                    bundleBytes: bundle, cacheBytes: libraryBytes("Caches", id: id),
                    dataBytes: libraryBytes("Application Support", id: id), includesLibrary: true
                )
            } else {
                result[app.installation] = InventoryFootprint(bundleBytes: bundle, cacheBytes: nil, dataBytes: nil, includesLibrary: false)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func libraryBytes(_ folder: String, id: String) -> Int64? {
        let location = library.appending(component: folder, directoryHint: .isDirectory).appending(component: id, directoryHint: .isDirectory)
        return directoryBytes(at: location, missing: 0)
    }

    private func directoryBytes(at location: URL, missing: Int64?) -> Int64? {
        do {
            guard let entry = try fileSystem.entry(at: location) else { return missing }
            guard entry.kind == .directory else { return nil }
            return try fileSystem.allocatedSize(of: location)
        } catch {
            return nil
        }
    }
}
