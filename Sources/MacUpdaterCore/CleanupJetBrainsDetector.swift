import Foundation

/// The folder names JetBrains IDEs write under `~/Library`: a product prefix and `20YY.N`, with
/// `-backup` for the copy an IDE keeps while it migrates settings.
public enum CleanupJetBrainsNames {
    /// A parsed folder name. A struct rather than a tuple, which the linter caps at two members.
    public struct FolderName: Equatable, Sendable {
        public let prefix: String
        public let version: String
        public let isBackup: Bool

        public init(prefix: String, version: String, isBackup: Bool) {
            self.prefix = prefix
            self.version = version
            self.isBackup = isBackup
        }
    }

    public static let productPrefixes = [
        "IntelliJIdea", "IdeaIC", "PyCharm", "PyCharmCE", "WebStorm", "GoLand", "CLion", "Rider", "RubyMine",
        "PhpStorm", "DataGrip", "DataSpell", "RustRover", "Aqua", "AppCode", "Writerside",
    ]

    /// The name each product's `.app` starts with, and the folder prefixes that product writes.
    static let displayNames: [(name: String, prefixes: [String])] = [
        ("IntelliJ IDEA", ["IntelliJIdea", "IdeaIC"]), ("PyCharm", ["PyCharm", "PyCharmCE"]),
        ("WebStorm", ["WebStorm"]), ("GoLand", ["GoLand"]), ("CLion", ["CLion"]), ("Rider", ["Rider"]),
        ("RubyMine", ["RubyMine"]), ("PhpStorm", ["PhpStorm"]), ("DataGrip", ["DataGrip"]),
        ("DataSpell", ["DataSpell"]), ("RustRover", ["RustRover"]), ("Aqua", ["Aqua"]), ("AppCode", ["AppCode"]),
        ("Writerside", ["Writerside"]),
    ]

    private static let backupSuffix = Array("-backup".unicodeScalars)
    private static let century = Array("20".unicodeScalars)
    private static let maxReleaseDigits = 2

    /// `IntelliJIdea2026.1-backup` → (`IntelliJIdea`, `2026.1`, true). The prefix whose remainder is
    /// a version wins, so `PyCharmCE2024.1` is PyCharm Community, not `PyCharm` and `CE2024.1`.
    public static func parse(_ name: String) -> FolderName? {
        let scalars = Array(name.unicodeScalars)
        for prefix in productPrefixes {
            let prefixScalars = Array(prefix.unicodeScalars)
            guard scalars.starts(with: prefixScalars),
                  let parsed = version(scalars.dropFirst(prefixScalars.count))
            else { continue }
            return FolderName(prefix: prefix, version: parsed.version, isBackup: parsed.isBackup)
        }
        return nil
    }

    /// `20YY.N` with an optional `-backup`, and nothing else.
    private static func version(_ remainder: ArraySlice<Unicode.Scalar>) -> (version: String, isBackup: Bool)? {
        let isBackup = remainder.reversed().starts(with: backupSuffix.reversed())
        let version = isBackup ? remainder.dropLast(backupSuffix.count) : remainder
        let year = version.prefix(4)
        let release = version.dropFirst(4)
        guard year.count == 4, year.starts(with: century), year.allSatisfy(isDigit),
              release.first == ".", (2...(1 + maxReleaseDigits)).contains(release.count), release.dropFirst().allSatisfy(isDigit)
        else { return nil }
        return (String(String.UnicodeScalarView(version)), isBackup)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}

/// D7: folders JetBrains IDEs left under `~/Library/Application Support`, `Caches` and `Logs` for
/// versions that are no longer installed. An IDE counts as installed only through its
/// `Contents/Resources/product-info.json` (`dataDirectoryName`), read as JSON and never executed.
/// Only a folder older than an installed IDE of its product is safe: a product with no IDE found,
/// or a folder newer than every installed one, may belong to an IDE outside the scanned
/// application folders, and a product with an IDE whose product-info cannot be read is left alone.
public struct CleanupJetBrainsDetector: Sendable {
    private static let dataLocations = ["Library/Application Support/JetBrains", "Library/Caches/JetBrains", "Library/Logs/JetBrains"]
    private static let toolboxApps = "Library/Application Support/JetBrains/Toolbox/apps"
    private static let toolboxDepth = 4
    private static let productInfo = "Contents/Resources/product-info.json"
    /// IntelliJ IDEA's product-info.json passes 500 KB (its `layout` array); only `dataDirectoryName` is decoded.
    private static let maxProductInfoBytes = 4_194_304

    private struct ProductInfo: Decodable {
        let dataDirectoryName: String?
    }

    /// What the application folders hold.
    private struct Installed {
        var names: Set<String> = []
        var unrecognisedPrefixes: Set<String> = []
        /// False when a folder that may hold an IDE could not be listed.
        var isComplete = true
    }

    private struct Candidate {
        let entry: CleanupEntry
        let prefix: String
        let version: String
    }

    private let fileSystem: CleanupFileSystem
    private let home: URL
    private let inspector: ProcessInspecting
    private let applicationDirectories: [URL]

    public init(fileSystem: CleanupFileSystem, home: URL, inspector: ProcessInspecting, applicationDirectories: [URL]) {
        self.fileSystem = fileSystem
        self.home = home
        self.inspector = inspector
        self.applicationDirectories = applicationDirectories
    }

    /// `/Applications`, `~/Applications` and the Toolbox's own install folder.
    public static func defaultApplicationDirectories(home: URL) -> [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
            home.appending(path: toolboxApps, directoryHint: .isDirectory),
        ]
    }

    public func findings() -> (findings: [CleanupFinding], notes: [CleanupDetectorNote]) {
        let installed = scanInstalled()
        let notes = installed.unrecognisedPrefixes.isEmpty ? [] : [CleanupDetectorNote(detector: .jetBrains, kind: .unrecognisedIDEInstall)]
        let versions = Self.versionsByPrefix(installed.names)
        let candidates = candidateFolders().filter { candidate in
            !installed.unrecognisedPrefixes.contains { Self.isSame($0, candidate.prefix) }
                && !Self.isInstalled(candidate, names: installed.names, versions: versions[candidate.prefix] ?? [])
        }
        let processes = candidates.isEmpty ? [] : inspector.userProcesses()
        let findings = candidates.map { candidate in
            finding(
                for: candidate, installed: versions[candidate.prefix] ?? [],
                evidenceComplete: installed.isComplete, processes: processes
            )
        }
        return (findings, notes)
    }

    /// Every installed IDE's `dataDirectoryName`, and the folder prefixes of the products with an
    /// IDE whose product-info could not be read.
    public func installedDataDirectoryNames() -> (names: Set<String>, unrecognisedPrefixes: Set<String>) {
        let installed = scanInstalled()
        return (installed.names, installed.unrecognisedPrefixes)
    }

    // MARK: Installed IDEs

    private func scanInstalled() -> Installed {
        var installed = Installed()
        let toolbox = CleanupPathText.components(of: home.appending(path: Self.toolboxApps, directoryHint: .isDirectory).path)
        for directory in applicationDirectories {
            let isToolbox = Self.isSamePath(CleanupPathText.components(of: directory.path), toolbox)
            for app in applications(in: directory, maxDepth: isToolbox ? Self.toolboxDepth : 1, installed: &installed) {
                record(app, into: &installed)
            }
        }
        return installed
    }

    /// The `.app` bundles, or links to one, at most `maxDepth` levels below `directory`. Only real
    /// directories are descended, never a bundle. A folder that is not there holds nothing; one that
    /// cannot be listed leaves the installed set incomplete.
    private func applications(in directory: URL, maxDepth: Int, installed: inout Installed) -> [URL] {
        var pending = [(url: directory, depth: 0)]
        var found: [URL] = []
        while let next = pending.popLast() {
            let entries: [CleanupEntry]
            do {
                entries = try fileSystem.contents(of: next.url)
            } catch CleanupFileSystemError.notFound {
                continue
            } catch {
                installed.isComplete = false
                continue
            }
            for entry in entries {
                if Self.hasSuffix(Self.name(of: entry.url), ".app"), entry.kind == .directory || entry.kind == .symlink {
                    found.append(entry.url)
                } else if entry.kind == .directory, next.depth + 1 < maxDepth {
                    pending.append((entry.url, next.depth + 1))
                }
            }
        }
        return found
    }

    /// An app named like a JetBrains product whose product-info cannot be read could be any version
    /// of that product, so the product's folders are left alone.
    private func record(_ app: URL, into installed: inout Installed) {
        if let name = dataDirectoryName(of: app) {
            installed.names.insert(name)
            return
        }
        let appName = Self.name(of: app)
        for product in CleanupJetBrainsNames.displayNames where Self.hasPrefix(appName, product.name) {
            installed.unrecognisedPrefixes.formUnion(product.prefixes)
        }
    }

    private func dataDirectoryName(of app: URL) -> String? {
        let url = app.appending(path: Self.productInfo, directoryHint: .notDirectory)
        guard let text = try? fileSystem.readText(url, maxBytes: Self.maxProductInfoBytes),
              let info = try? JSONDecoder().decode(ProductInfo.self, from: Data(text.utf8)),
              let name = info.dataDirectoryName, !name.isEmpty
        else { return nil }
        return name
    }

    /// The installed versions of each product, oldest first.
    private static func versionsByPrefix(_ names: Set<String>) -> [String: [String]] {
        var versions: [String: Set<String>] = [:]
        for name in names {
            guard let parsed = CleanupJetBrainsNames.parse(name), !parsed.isBackup else { continue }
            versions[parsed.prefix, default: []].insert(parsed.version)
        }
        return versions.mapValues { found in
            found.sorted { compareVersions($0, $1, scheme: .semver) == .orderedAscending }
        }
    }

    private static func isInstalled(_ candidate: Candidate, names: Set<String>, versions: [String]) -> Bool {
        let base = candidate.prefix + candidate.version
        return names.contains { isSame($0, base) }
            || versions.contains { compareVersions(candidate.version, $0, scheme: .semver) == .orderedSame }
    }

    // MARK: Candidates

    private func candidateFolders() -> [Candidate] {
        Self.dataLocations.flatMap { location -> [Candidate] in
            let directory = home.appending(path: location, directoryHint: .isDirectory)
            guard let entries = try? fileSystem.contents(of: directory) else { return [] }
            return entries.filter { $0.kind == .directory }.compactMap { entry in
                guard let parsed = CleanupJetBrainsNames.parse(Self.name(of: entry.url)) else { return nil }
                return Candidate(entry: entry, prefix: parsed.prefix, version: parsed.version)
            }
        }
    }

    private func finding(
        for candidate: Candidate, installed: [String], evidenceComplete: Bool, processes: [CleanupProcess]
    ) -> CleanupFinding {
        let url = candidate.entry.url
        let realpath = try? fileSystem.realpath(url)
        let users = Self.users(of: [url] + (realpath.map { [$0] } ?? []), among: processes)
        let status: CleanupStatus = users.isEmpty ? .unused : .inUse(users)
        let verdict = Self.reason(version: candidate.version, installed: installed)
        return CleanupFinding(
            detector: .jetBrains, tool: candidate.prefix, path: url, realpath: realpath, source: nil,
            version: candidate.version, size: try? fileSystem.allocatedSize(of: url), status: status,
            reason: verdict.reason, action: .trash([url]), risk: .low,
            bucket: CleanupBucketPolicy.bucket(
                status: status, kind: .jetBrainsDirectory, evidenceComplete: verdict.isExplained && evidenceComplete
            ),
            identity: candidate.entry.identity
        )
    }

    /// Only a folder older than an installed IDE of its product is explained by an upgrade.
    private static func reason(version: String, installed: [String]) -> (reason: CleanupReason, isExplained: Bool) {
        guard !installed.isEmpty else { return (.ideNotFound, false) }
        let isNewest = installed.allSatisfy { compareVersions(version, $0, scheme: .semver) == .orderedDescending }
        return isNewest ? (.newerThanInstalledIDE(installed: installed), false) : (.ideVersionNotInstalled(installed: installed), true)
    }

    /// A process runs from the folder or names it in an argument, under the listed or physical path.
    private static func users(of roots: [URL], among processes: [CleanupProcess]) -> [CleanupProcess] {
        let matched = Set(roots.flatMap { root in
            CleanupInUseMatcher.processes(using: root, isDirectory: true, among: processes)
                + CleanupInUseMatcher.processes(referencing: root, among: processes)
        }.map(\.pid))
        return processes.filter { matched.contains($0.pid) }
    }

    // MARK: Names

    private static func name(of url: URL) -> String {
        CleanupPathText.components(of: url.path).last ?? ""
    }

    private static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    private static func isSamePath(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { isSame($0, $1) }
    }

    private static func hasPrefix(_ name: String, _ prefix: String) -> Bool {
        name.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// `name` ends in `suffix` and has at least one scalar before it.
    private static func hasSuffix(_ name: String, _ suffix: String) -> Bool {
        name.unicodeScalars.count > suffix.unicodeScalars.count
            && name.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
    }
}
