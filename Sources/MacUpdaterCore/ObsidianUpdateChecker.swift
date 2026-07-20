import Foundation

/// Detects Obsidian's in-app package updates, including the Catalyst insider channel.
/// Obsidian can load a newer `obsidian-X.Y.Z.asar` from Application Support while its
/// app bundle and Homebrew cask remain on the last installer release.
public struct ObsidianUpdateChecker: Sendable {
    public static let bundleIdentifier = "md.obsidian"

    private let client: HTTPClient
    private let releasesURL: URL
    private let applicationSupportDirectory: URL

    public init(client: HTTPClient = .shared) {
        self.init(
            client: client,
            releasesURL: AppEndpoints.shared.obsidianDesktopReleasesURL,
            applicationSupportDirectory: Self.defaultApplicationSupportDirectory
        )
    }

    init(client: HTTPClient, releasesURL: URL, applicationSupportDirectory: URL) {
        self.client = client
        self.releasesURL = releasesURL
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard app.bundleIdentifier == Self.bundleIdentifier,
              let installed = installedVersion(fallingBackTo: app.version)
        else { return .notApplicable }

        guard let response = try? await client.get(releasesURL, enableETag: true) else {
            return .unavailable
        }
        guard response.statusCode == 200 else {
            return response.statusCode >= 500 ? .unavailable : .failed
        }
        guard let releases = try? JSONDecoder().decode(ObsidianDesktopReleases.self, from: response.data) else {
            return .failed
        }

        let latest = isInsiderEnabled
            ? releases.beta?.latestVersion ?? releases.latestVersion
            : releases.latestVersion
        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: installed,
            availableVersion: latest,
            source: .obsidian
        ))
    }

    private static var defaultApplicationSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("obsidian", isDirectory: true)
    }

    private var isInsiderEnabled: Bool {
        let settingsURL = applicationSupportDirectory.appendingPathComponent("obsidian.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(ObsidianSettings.self, from: data)
        else { return false }
        return settings.insider ?? false
    }

    private func installedVersion(fallingBackTo bundleVersion: String?) -> String? {
        let packageVersions = (try? FileManager.default.contentsOfDirectory(
            at: applicationSupportDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.compactMap(Self.packageVersion(from:)) ?? []

        return packageVersions.reduce(bundleVersion) { current, candidate in
            guard let current else { return candidate }
            return isUpgrade(installed: current, latest: candidate) ? candidate : current
        }
    }

    private static func packageVersion(from url: URL) -> String? {
        let name = url.lastPathComponent
        let prefix = "obsidian-"
        let suffix = ".asar"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let version = name.dropFirst(prefix.count).dropLast(suffix.count)
        return version.isEmpty ? nil : String(version)
    }
}

private struct ObsidianDesktopReleases: Decodable {
    let latestVersion: String
    let beta: ObsidianRelease?
}

private struct ObsidianRelease: Decodable {
    let latestVersion: String
}

private struct ObsidianSettings: Decodable {
    let insider: Bool?
}
