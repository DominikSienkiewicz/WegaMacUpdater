import Foundation

public struct CaskReleaseNotesRequest: Hashable, Sendable {
    public let appPath: URL
    public let targetVersion: String

    public init?(item: OutdatedItem, appPath: URL?) {
        guard item.kind == .cask, let appPath, let target = item.to, !target.isEmpty else { return nil }
        self.appPath = appPath
        targetVersion = target
    }
}

/// Fetches metadata on demand, independently of which source owns the installation action.
public struct CaskReleaseNotesProvider: Sendable {
    public enum Outcome: Equatable, Sendable {
        case notes(ReleaseNotes)
        case unavailable
        case failed
    }

    private let sparkle: SparkleUpdateChecker
    private let github: GitHubReleasesChecker

    public init(sparkle: SparkleUpdateChecker = SparkleUpdateChecker(), github: GitHubReleasesChecker = GitHubReleasesChecker()) {
        self.sparkle = sparkle
        self.github = github
    }

    public func notes(for request: CaskReleaseNotesRequest) async -> Outcome {
        guard let app = application(at: request.appPath) else { return .unavailable }
        var failed = false
        if let plan = sparkle.plan(for: app) {
            if let data = await payload(plan.request, client: sparkle.client),
               let items = AppcastParser.parsedCandidates(data: data) {
                if let notes = AppcastParser.releaseNotes(items: items, targetVersion: request.targetVersion), !notes.isEmpty {
                    return .notes(notes)
                }
            } else { failed = true }
        }
        if let plan = github.plan(for: app) {
            if let data = await payload(plan.request, client: github.client),
               let releases = GitHubReleaseHistory.stableReleases(from: data) {
                let matches = releases.filter { normalizeGitTag($0.tagName) == request.targetVersion }
                if matches.count == 1, let release = matches.first {
                    let notes = ReleaseNotes(html: release.body ?? "", version: request.targetVersion,
                                             publishedAt: release.publishedAt.flatMap(GitHubReleaseHistory.iso8601Date))
                    if !notes.isEmpty { return .notes(notes) }
                }
            } else { failed = true }
        }
        return failed ? .failed : .unavailable
    }

    private func payload(_ request: HTTPRequest, client: HTTPClient) async -> Data? {
        guard !Task.isCancelled, let response = try? await client.send(request), response.statusCode == 200 else { return nil }
        return response.data
    }

    private func application(at path: URL) -> ApplicationInfo? {
        guard let data = try? Data(contentsOf: path.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return ApplicationInfo(
            path: path, name: path.deletingPathExtension().lastPathComponent,
            bundleIdentifier: plist["CFBundleIdentifier"] as? String,
            version: plist["CFBundleShortVersionString"] as? String, buildVersion: plist["CFBundleVersion"] as? String,
            installDate: nil, updateDate: nil, isManagedByBrew: true, caskToken: nil
        )
    }
}

extension AppcastParser {
    static func releaseNotes(data: Data, targetVersion: String) -> ReleaseNotes? {
        releaseNotes(items: candidates(data: data), targetVersion: targetVersion)
    }

    static func releaseNotes(items: [AppcastItem], targetVersion: String) -> ReleaseNotes? {
        let matches = items.filter { item in
            if let short = item.shortVersion, let build = item.buildVersion {
                return targetVersion == short || targetVersion == "\(short),\(build)"
                    || targetVersion == AppcastItem.label(version: short, build: build)
            }
            return targetVersion == item.version
        }
        // A marketing version shared by several builds does not identify one release.
        guard matches.count == 1, let match = matches.first else { return nil }
        return ReleaseNotes(html: match.descriptionHTML ?? "", version: match.label(includingBuild: true) ?? targetVersion,
                            publishedAt: match.publishedAt, link: match.releaseNotesLink)
    }
}
