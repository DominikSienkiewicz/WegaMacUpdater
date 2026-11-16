import Foundation

/// Asked by `CleanupRemover`, under its write lease and right before it trashes a D6 or D7 item,
/// whether what made the item unneeded at scan time still holds. A wrapper, toolchain or IDE that
/// appeared since makes it needed again, and the removal asks for a rescan.
public protocol CleanupReferenceRechecking: Sendable {
    func isStillUnreferenced(_ finding: CleanupFinding) async throws -> Bool
}

/// Re-checks nothing: every item is still unreferenced.
public struct CleanupNoReferenceRecheck: CleanupReferenceRechecking {
    public init() {}

    public func isStillUnreferenced(_ finding: CleanupFinding) async throws -> Bool { true }
}

/// Reads again what D6 and D7 read: the project roots as Settings name them at removal time
/// (the remover outlives a Settings change), the trashed JDK's major and the installed IDEs.
///
/// A root the walk cannot read holds no reference it can see: the user already confirmed an item
/// that needed a decision, so only a reference that is visible now keeps the item. An item the
/// re-check cannot identify (a name that no longer parses, a D6 reason that names no candidate)
/// and a JDK that is no longer the major the scan saw are kept. Findings of the other detectors
/// have nothing to re-check.
public struct CleanupLiveReferenceRecheck: CleanupReferenceRechecking {
    private let fileSystem: CleanupFileSystem
    private let projectRoots: @Sendable () -> [URL]
    private let gradle: CleanupGradleDetector
    private let jetBrains: CleanupJetBrainsDetector

    public init(
        fileSystem: CleanupFileSystem, home: URL, inspector: ProcessInspecting,
        projectRoots: @escaping @Sendable () -> [URL], applicationDirectories: [URL]
    ) {
        self.fileSystem = fileSystem
        self.projectRoots = projectRoots
        gradle = CleanupGradleDetector(fileSystem: fileSystem, home: home, inspector: inspector)
        jetBrains = CleanupJetBrainsDetector(
            fileSystem: fileSystem, home: home, inspector: inspector, applicationDirectories: applicationDirectories
        )
    }

    /// Throws only `CancellationError`, from the project walk.
    public func isStillUnreferenced(_ finding: CleanupFinding) async throws -> Bool {
        guard case .trash(let urls) = finding.action, finding.detector == .gradle || finding.detector == .jetBrains else {
            return true
        }
        guard urls.count == 1, let item = urls.first else { return false }
        if finding.detector == .jetBrains {
            return isUninstalledIDEFolder(item)
        }
        switch finding.reason {
        case .unusedGradleDistribution:
            return try isUnreferencedDistribution(item)
        case .unreferencedJDK(let major):
            return try isUnrequiredJDK(item, scannedMajor: major)
        default:
            return false
        }
    }

    private func isUnreferencedDistribution(_ directory: URL) throws -> Bool {
        guard let distribution = CleanupGradleDistribution.named(Self.name(of: directory)) else { return false }
        return !gradle.referencedDistributions(projectFiles: try projectFiles()).contains(distribution)
    }

    private func isUnrequiredJDK(_ directory: URL, scannedMajor: Int) throws -> Bool {
        guard gradle.javaMajor(ofJDK: directory) == scannedMajor else { return false }
        return !gradle.requiredJavaMajors(projectFiles: try projectFiles()).contains(scannedMajor)
    }

    /// The scan's rule for an installed version: an IDE whose `dataDirectoryName` is the folder's
    /// base name or names the same release of its product, or an IDE of its product whose
    /// product-info cannot be read. A `-backup` folder belongs to the release it backs up.
    private func isUninstalledIDEFolder(_ directory: URL) -> Bool {
        guard let folder = CleanupJetBrainsNames.parse(Self.name(of: directory)) else { return false }
        let installed = jetBrains.installedDataDirectoryNames()
        if installed.unrecognisedPrefixes.contains(where: { Self.isSame($0, folder.prefix) }) { return false }
        let baseName = folder.prefix + folder.version
        return !installed.names.contains { name in
            Self.isSame(name, baseName) || Self.isSameRelease(name, as: folder)
        }
    }

    private static func isSameRelease(_ name: String, as folder: CleanupJetBrainsNames.FolderName) -> Bool {
        guard let installed = CleanupJetBrainsNames.parse(name), !installed.isBackup else { return false }
        return isSame(installed.prefix, folder.prefix)
            && compareVersions(installed.version, folder.version, scheme: .semver) == .orderedSame
    }

    private func projectFiles() throws -> [CleanupProjectFile] {
        try CleanupProjectWalker(fileSystem: fileSystem).walk(roots: projectRoots()).files
    }

    private static func name(of url: URL) -> String {
        CleanupPathText.components(of: url.path).last ?? ""
    }

    private static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }
}
