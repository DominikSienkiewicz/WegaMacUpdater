import Foundation

public struct JetBrainsUpdateChecker: Sendable {
    private let client: HTTPClient
    private let products: [String: JetBrainsCatalogEntry]

    public init(
        client: HTTPClient = .shared,
        products: [String: JetBrainsCatalogEntry] = AppCatalog.shared.jetbrainsProducts
    ) {
        self.client = client
        self.products = products
    }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard let bundleId = app.bundleIdentifier,
              let product = products[bundleId] else { return .notApplicable }

        guard let url = AppEndpoints.shared.jetbrainsReleasesURL(code: product.code) else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .unavailable }
        guard response.statusCode == 200 else { return response.statusCode >= 500 ? .unavailable : .failed }
        guard let releases = try? JSONDecoder().decode([String: [JetBrainsRelease]].self, from: response.data),
              let latest = releases[product.code]?.first?.version else { return .failed }

        let installed = app.version ?? ""
        guard !installed.isEmpty else { return .notApplicable }
        guard isUpgrade(installed: installed, latest: latest) else { return .upToDate }

        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest,
            source: .jetbrains(caskToken: product.caskToken)
        ))
    }
}

/// One release entry from JetBrains' `data.services.jetbrains.com` releases feed.
/// `whatsnew` is the HTML changelog blob the feed ships per release; it is optional
/// because older/other entries omit it. Kept `internal` (not `private`) so the parser
/// layer is unit-testable. Raw HTML is returned untouched — rendering is a UI concern.
struct JetBrainsRelease: Decodable {
    let version: String
    let whatsnew: String?
}
