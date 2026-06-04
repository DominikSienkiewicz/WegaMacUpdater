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

        let urlString = "https://data.services.jetbrains.com/products/releases?code=\(product.code)&latest=true&type=release"
        guard let url = URL(string: urlString) else { return .notApplicable }

        guard let response = try? await client.get(url, enableETag: true) else { return .failed }
        guard response.statusCode == 200,
              let releases = try? JSONDecoder().decode([String: [JetBrainsRelease]].self, from: response.data),
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

private struct JetBrainsRelease: Decodable {
    let version: String
}
