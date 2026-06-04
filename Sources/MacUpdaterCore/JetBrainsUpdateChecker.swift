import Foundation

public struct JetBrainsUpdateChecker: Sendable {
    private let session: URLSession
    private let products: [String: JetBrainsCatalogEntry]

    public init(
        session: URLSession = .shared,
        products: [String: JetBrainsCatalogEntry] = AppCatalog.shared.jetbrainsProducts
    ) {
        self.session = session
        self.products = products
    }

    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        guard let bundleId = app.bundleIdentifier,
              let product = products[bundleId] else { return nil }

        let urlString = "https://data.services.jetbrains.com/products/releases?code=\(product.code)&latest=true&type=release"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try? JSONDecoder().decode([String: [JetBrainsRelease]].self, from: data),
              let latest = releases[product.code]?.first?.version else { return nil }

        let installed = app.version ?? ""
        guard !installed.isEmpty, isUpgrade(installed: installed, latest: latest) else { return nil }

        return ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest,
            source: .jetbrains(caskToken: product.caskToken)
        )
    }
}

private struct JetBrainsRelease: Decodable {
    let version: String
}
