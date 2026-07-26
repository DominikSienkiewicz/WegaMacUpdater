import Foundation

public struct JetBrainsUpdateChecker: VendorUpdateChecker {
    public let client: HTTPClient
    private let products: [String: JetBrainsCatalogEntry]

    public init(
        client: HTTPClient = .shared,
        products: [String: JetBrainsCatalogEntry] = AppCatalog.shared.jetbrainsProducts
    ) {
        self.client = client
        self.products = products
    }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard let bundleId = app.bundleIdentifier,
              let product = products[bundleId] else { return nil }

        guard let url = AppEndpoints.shared.jetbrainsReleasesURL(code: product.code) else { return nil }

        return VendorCheckPlan(request: HTTPRequest(url: url, enableETag: true)) { data in
            guard let releases = try? JSONDecoder().decode([String: [JetBrainsRelease]].self, from: data),
                  let latest = releases[product.code]?.first?.version else { return .decided(.failed) }

            let installed = app.version ?? ""
            guard !installed.isEmpty else { return .decided(.notApplicable) }
            return .candidate(VendorCandidate(
                latest: latest,
                installed: installed,
                recordedInstalled: app.version,
                source: .jetbrains(caskToken: product.caskToken)
            ))
        }
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
