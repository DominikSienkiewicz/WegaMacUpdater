import Foundation

/// A requirement file the project walk hands to D5 (runtime versions) or D6 (Gradle).
public enum CleanupProjectFileKind: String, Codable, Sendable {
    case pythonVersion, nvmrc, nodeVersion, toolVersions, miseToml, pyprojectToml, packageJson, sdkmanrc
    case rustToolchain, rustToolchainToml, gradleWrapperProperties, gradleDaemonJvmProperties, gradleBuildScript, pyvenvCfg
}

public struct CleanupProjectFile: Equatable, Sendable {
    public let url: URL
    public let kind: CleanupProjectFileKind
    public let text: String

    public init(url: URL, kind: CleanupProjectFileKind, text: String) {
        self.url = url
        self.kind = kind
        self.text = text
    }
}

/// What one walk over the configured project roots found.
public struct CleanupProjectWalk: Equatable, Sendable {
    public let files: [CleanupProjectFile]
    /// The roots whose own listing succeeded.
    public let walkedRoots: [URL]
    /// The roots with no directory at their path: absent, a file, or a symlink (never followed).
    public let missingRoots: [URL]
    /// The paths the protected-location guard refused, spelled as the guard reports them.
    public let skippedProtected: [String]
    /// A directory could not be listed, or `maxDirectories` / `maxFiles` stopped the walk, so
    /// `files` may lack requirements that exist.
    public let truncated: Bool

    public var isComplete: Bool { !walkedRoots.isEmpty && !truncated }

    public init(files: [CleanupProjectFile], walkedRoots: [URL], missingRoots: [URL], skippedProtected: [String], truncated: Bool) {
        self.files = files
        self.walkedRoots = walkedRoots
        self.missingRoots = missingRoots
        self.skippedProtected = skippedProtected
        self.truncated = truncated
    }
}

/// Reads the requirement files under the project roots once per scan (spec §6.5.1), through the
/// injected (guarded) file system only.
///
/// Only entries whose `lstat` kind is `.directory` are descended, so no symlink is ever followed;
/// the skip list is never entered, and `.venv` only for its `pyvenv.cfg`. Only the listed file
/// names are read — never `gradle.properties` or `local.properties` — each as UTF-8 of at most
/// `maxFileBytes`; any other file is skipped. A refused path is recorded and the walk goes on.
/// Any other listing failure, or reaching `maxDirectories` or `maxFiles`, truncates the walk.
/// `maxDepth` is the walk's scope rather than missing evidence: a root's own entries are level 1
/// and nothing below level `maxDepth` is touched, without truncating.
public struct CleanupProjectWalker: Sendable {
    private struct Directory {
        let url: URL
        let depth: Int
        /// The directory names from below the root down to this directory.
        let names: [String]
    }

    private struct Progress {
        var files: [CleanupProjectFile] = []
        var walkedRoots: [URL] = []
        var missingRoots: [URL] = []
        var skippedProtected: [String] = []
        var truncated = false
        var stopped = false
        var listedDirectories = 0

        mutating func refused(_ path: String) {
            if !skippedProtected.contains(where: { CleanupPathText.isSameName($0, path) }) {
                skippedProtected.append(path)
            }
        }

        mutating func stop() {
            truncated = true
            stopped = true
        }
    }

    private static let requirementFiles: [(name: String, kind: CleanupProjectFileKind)] = [
        (".python-version", .pythonVersion), (".nvmrc", .nvmrc), (".node-version", .nodeVersion),
        (".tool-versions", .toolVersions), ("mise.toml", .miseToml), (".mise.toml", .miseToml),
        ("pyproject.toml", .pyprojectToml), ("package.json", .packageJson), (".sdkmanrc", .sdkmanrc),
        ("rust-toolchain", .rustToolchain), ("rust-toolchain.toml", .rustToolchainToml),
    ]
    private static let skippedDirectories = [
        ".git", "node_modules", "build", ".build", ".gradle", "target", "DerivedData", "Pods", "dist",
    ]
    private static let gradleScriptSuffixes = [".gradle", ".gradle.kts"]
    private static let buildLogicDirectories = ["buildSrc", "build-logic"]
    private static let virtualEnvironment = ".venv"

    private let fileSystem: CleanupFileSystem
    private let maxDepth: Int
    private let maxFileBytes: Int
    private let maxFiles: Int
    private let maxDirectories: Int

    public init(fileSystem: CleanupFileSystem, maxDepth: Int = 8, maxFileBytes: Int = 262_144, maxFiles: Int = 2_000, maxDirectories: Int = 50_000) {
        self.fileSystem = fileSystem
        self.maxDepth = maxDepth
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.maxDirectories = maxDirectories
    }

    /// Throws only `CancellationError`, checked before every directory is listed.
    public func walk(roots: [URL]) throws -> CleanupProjectWalk {
        var progress = Progress()
        for root in roots {
            guard !progress.stopped else { break }
            try walk(root: root, progress: &progress)
        }
        return CleanupProjectWalk(
            files: progress.files, walkedRoots: progress.walkedRoots, missingRoots: progress.missingRoots,
            skippedProtected: progress.skippedProtected, truncated: progress.truncated
        )
    }

    private func walk(root: URL, progress: inout Progress) throws {
        guard try isWalkable(root, progress: &progress) else { return }
        var pending = [Directory(url: root, depth: 0, names: [])]
        while let directory = pending.popLast(), !progress.stopped {
            try Task.checkCancellation()
            guard let entries = try list(directory.url, progress: &progress) else { continue }
            if directory.depth == 0 { progress.walkedRoots.append(root) }
            pending += try visit(entries, in: directory, progress: &progress).reversed()
        }
    }

    /// Reads the requirement files among `entries` and returns the subdirectories to list, in name order.
    private func visit(_ entries: [CleanupEntry], in directory: Directory, progress: inout Progress) throws -> [Directory] {
        var subdirectories: [Directory] = []
        for entry in entries {
            guard !progress.stopped else { break }
            let name = CleanupPathText.components(of: entry.url.path).last ?? ""
            switch entry.kind {
            case .file:
                if let kind = Self.kind(ofFile: name, in: directory.names) {
                    try read(entry.url, kind: kind, progress: &progress)
                }
            case .directory:
                if directory.depth + 1 < maxDepth, Self.isEntered(name, from: directory.names) {
                    subdirectories.append(Directory(url: entry.url, depth: directory.depth + 1, names: directory.names + [name]))
                }
            case .symlink, .other:
                continue
            }
        }
        return subdirectories
    }

    private func isWalkable(_ root: URL, progress: inout Progress) throws -> Bool {
        do {
            guard let entry = try fileSystem.entry(at: root), entry.kind == .directory else {
                progress.missingRoots.append(root)
                return false
            }
            return true
        } catch CleanupFileSystemError.notFound {
            progress.missingRoots.append(root)
        } catch CleanupFileSystemError.protectedLocation(let refused) {
            progress.refused(refused)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            progress.truncated = true
        }
        return false
    }

    /// The directory's entries; nil when it was refused, could not be listed or the cap was reached.
    private func list(_ directory: URL, progress: inout Progress) throws -> [CleanupEntry]? {
        guard progress.listedDirectories < maxDirectories else {
            progress.stop()
            return nil
        }
        progress.listedDirectories += 1
        do {
            return try fileSystem.contents(of: directory)
        } catch CleanupFileSystemError.protectedLocation(let refused) {
            progress.refused(refused)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            progress.truncated = true
        }
        return nil
    }

    /// A file too large, unreadable or not UTF-8 is skipped without truncating the walk.
    private func read(_ url: URL, kind: CleanupProjectFileKind, progress: inout Progress) throws {
        guard progress.files.count < maxFiles else {
            progress.stop()
            return
        }
        do {
            let text = try fileSystem.readText(url, maxBytes: maxFileBytes)
            progress.files.append(CleanupProjectFile(url: url, kind: kind, text: text))
        } catch CleanupFileSystemError.protectedLocation(let refused) {
            progress.refused(refused)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            return
        }
    }

    /// The kind of the file `name` in the directory reached through `names`; nil for a file that is never read.
    private static func kind(ofFile name: String, in names: [String]) -> CleanupProjectFileKind? {
        if isVirtualEnvironment(names) {
            return CleanupPathText.isSameName(name, "pyvenv.cfg") ? .pyvenvCfg : nil
        }
        if let file = requirementFiles.first(where: { CleanupPathText.isSameName($0.name, name) }) {
            return file.kind
        }
        if CleanupPathText.isSameName(name, "gradle-wrapper.properties") {
            return endsWith(names, "gradle", "wrapper") ? .gradleWrapperProperties : nil
        }
        if CleanupPathText.isSameName(name, "gradle-daemon-jvm.properties") {
            return endsWith(names, "gradle") ? .gradleDaemonJvmProperties : nil
        }
        if gradleScriptSuffixes.contains(where: { CleanupPathText.hasNameSuffix(name, $0) }) {
            return .gradleBuildScript
        }
        let isBuildLogic = names.contains { directory in
            buildLogicDirectories.contains { CleanupPathText.isSameName(directory, $0) }
        }
        return isBuildLogic && CleanupPathText.hasNameSuffix(name, ".kt") ? .gradleBuildScript : nil
    }

    /// Whether the subdirectory `name` of the directory reached through `names` is listed.
    private static func isEntered(_ name: String, from names: [String]) -> Bool {
        !isVirtualEnvironment(names) && !skippedDirectories.contains { CleanupPathText.isSameName($0, name) }
    }

    private static func isVirtualEnvironment(_ names: [String]) -> Bool {
        endsWith(names, virtualEnvironment)
    }

    private static func endsWith(_ names: [String], _ suffix: String...) -> Bool {
        names.count >= suffix.count && zip(names.suffix(suffix.count), suffix).allSatisfy { CleanupPathText.isSameName($0, $1) }
    }
}

private extension CleanupPathText {
    static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    /// `name` ends in `suffix` and has at least one scalar before it.
    static func hasNameSuffix(_ name: String, _ suffix: String) -> Bool {
        name.unicodeScalars.count > suffix.unicodeScalars.count
            && name.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
    }
}
