import Foundation

public struct SynologyRelease: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let publishDate: String?
}

public enum SynologyApiParser {
    private struct Response: Decodable {
        let info: Info?
        struct Info: Decodable {
            let versions: [String: [String: [Entry]]]?
        }
        struct Entry: Decodable {
            let version: String
            let publish_date: String?
        }
    }

    public static func latestRelease(from data: Data) -> SynologyRelease? {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let versions = decoded.info?.versions else { return nil }

        let allEntries = versions.values.flatMap { $0.values.flatMap { $0 } }
        let candidate = allEntries
            .compactMap { entry -> SynologyRelease? in
                guard let build = buildNumber(fromVersionString: entry.version) else { return nil }
                return SynologyRelease(version: entry.version, build: build, publishDate: entry.publish_date)
            }
            .max(by: { $0.build < $1.build })

        return candidate
    }

    public static func buildNumber(fromVersionString string: String) -> Int? {
        guard let dashIndex = string.lastIndex(of: "-") else { return nil }
        let buildPart = string[string.index(after: dashIndex)...]
        return Int(buildPart)
    }
}

public struct SynologyUpdateChecker: Sendable {
    private let client: HTTPClient
    private let mappings: [String: SynologyCatalogEntry]

    public init(
        client: HTTPClient = .shared,
        mappings: [String: SynologyCatalogEntry] = AppCatalog.shared.synologyMappings
    ) {
        self.client = client
        self.mappings = mappings
    }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard let bundleId = app.bundleIdentifier,
              let mapping = mappings[bundleId] else { return .notApplicable }

        guard let installedBuild = installedBuildNumber(for: app) else { return .notApplicable }

        guard let url = AppEndpoints.shared.synologyChangeLogURL(identify: mapping.identify) else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .failed }
        guard response.statusCode == 200,
              let latest = SynologyApiParser.latestRelease(from: response.data) else { return .failed }

        guard latest.build > installedBuild else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest.version,
            source: .synology(downloadPage: mapping.downloadPage)
        ))
    }

    private func installedBuildNumber(for app: ApplicationInfo) -> Int? {
        let infoPlistURL = app.path.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        if let raw = plist["CFBundleVersion"] as? String, let n = Int(raw) {
            return n
        }
        if let raw = plist["CFBundleVersion"] as? Int {
            return raw
        }
        return nil
    }
}
