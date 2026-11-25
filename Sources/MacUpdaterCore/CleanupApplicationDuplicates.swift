import Foundation
import WegaHelperKit

struct CleanupApplicationDuplicates {
    private static let maxPlistBytes = 1_048_576

    private struct Copy {
        let entry: CleanupEntry
        let name: String
        let bundleIdentifier: String
        let version: String?

        func finding() -> CleanupFinding {
            CleanupFinding(
                detector: .applicationDuplicates, tool: name, path: entry.url, realpath: nil,
                source: nil, version: version, size: nil, status: .info,
                reason: .duplicateApplication(bundleIdentifier: bundleIdentifier), action: .none,
                risk: .low, bucket: .needsDecision, identity: entry.identity
            )
        }
    }

    let fileSystem: any CleanupFileSystem

    func findings(home: URL, configuration: ScanConfiguration?, fallbackDirectories: [URL]) throws -> [CleanupFinding] {
        let roots = configuration.map {
            [SystemPaths.applicationsDirectory, home.appending(component: "Applications", directoryHint: .isDirectory)]
                + $0.userDirectories
        } ?? fallbackDirectories
        let exclusions = (configuration?.exclusions ?? []).map {
            ProtectedLocationGuard.standardizedPath((try? fileSystem.realpath($0)) ?? $0)
        }
        var directories = Set<String>()
        var copies: [Copy] = []
        var entries = Set<CleanupFileIdentity>()
        let maxDepth = ScanConfiguration.clamp(configuration?.recursionDepth ?? 0)
        var pending = roots.reversed().map { (url: $0, depth: 0) }
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            guard let resolved = try? fileSystem.realpath(directory.url) else { continue }
            let path = ProtectedLocationGuard.standardizedPath(resolved)
            guard !exclusions.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  directories.insert(path).inserted,
                  let children = try? fileSystem.contents(of: directory.url) else { continue }
            for entry in children where entry.kind == .directory && !entry.url.lastPathComponent.hasPrefix(".") {
                if entry.url.pathExtension == "app" {
                    if entries.insert(entry.identity).inserted, let app = copy(at: entry) { copies.append(app) }
                } else if directory.depth < maxDepth {
                    pending.append((entry.url, directory.depth + 1))
                }
            }
        }
        let groups = Dictionary(grouping: copies, by: \.bundleIdentifier)
        return groups.values.filter { $0.count > 1 }
            .flatMap { $0.map { $0.finding() } }
            .sorted { $0.path.path < $1.path.path }
    }

    private func copy(at entry: CleanupEntry) -> Copy? {
        let plist = entry.url.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard (try? fileSystem.entry(at: plist))?.kind == .file,
              let data = try? fileSystem.readData(plist, maxBytes: Self.maxPlistBytes),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = values["CFBundleIdentifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Copy(
            entry: entry, name: values["CFBundleName"] as? String ?? entry.url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: identifier, version: values["CFBundleShortVersionString"] as? String ?? values["CFBundleVersion"] as? String
        )
    }
}
