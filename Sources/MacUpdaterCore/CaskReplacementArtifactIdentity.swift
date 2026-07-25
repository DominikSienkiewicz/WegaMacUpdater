import Foundation

/// Stable identity of the concrete app bundle protected by a replacement snapshot.
///
/// A cask token can install several `.app` artifacts. Replacement flows therefore carry
/// the snapshotted bundle's name and identifier across the Homebrew mutation instead of
/// accepting whichever artifact happens to appear first in cask metadata afterwards.
public struct CaskReplacementArtifactIdentity: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let artifactName: String

    public init(bundleIdentifier: String?, appURL: URL) {
        self.bundleIdentifier = bundleIdentifier
        artifactName = appURL.lastPathComponent
    }

    /// Returns the single declared artifact whose bundle name matches the snapshot.
    /// Missing and duplicate matches are both unsafe because neither identifies one target.
    public func matchingArtifact(
        token: String,
        in installationInfo: [BrewCaskInstallationInfo]
    ) -> String? {
        let matches = installationInfo
            .filter { $0.token == token }
            .flatMap(\.appArtifacts)
            .filter { URL(fileURLWithPath: $0).lastPathComponent == artifactName }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// Reads the plist directly so an in-place replacement cannot reuse `Bundle`'s cache.
    public static func bundleIdentifier(at appURL: URL) -> String? {
        let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return values["CFBundleIdentifier"] as? String
    }
}

public enum CaskReplacementArtifactLocation: Equatable, Sendable {
    case resolved(URL)
    case unresolved
    case ambiguous
}

/// Resolves one already-selected cask artifact without silently preferring an install root.
public struct CaskReplacementArtifactLocationResolver {
    private let applicationsDirectory: URL
    private let userApplicationsDirectory: URL
    private let fileExists: (URL) -> Bool

    public init(
        applicationsDirectory: URL = SystemPaths.applicationsDirectory,
        userApplicationsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true),
        fileExists: @escaping (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) {
        self.applicationsDirectory = applicationsDirectory
        self.userApplicationsDirectory = userApplicationsDirectory
        self.fileExists = fileExists
    }

    public func resolve(artifact: String) -> CaskReplacementArtifactLocation {
        let matches = [applicationsDirectory, userApplicationsDirectory]
            .map { $0.appendingPathComponent(artifact) }
            .filter(fileExists)

        switch matches.count {
        case 0:
            return .unresolved
        case 1:
            return .resolved(matches[0])
        default:
            return .ambiguous
        }
    }
}
