import Foundation

/// Detects updates for Creative Cloud applications.
///
/// Adobe ships no Sparkle feed, no Squirrel endpoint and — for everything past Acrobat
/// Reader — no Homebrew cask, so every source the other checkers use is absent and an
/// outdated Lightroom or Photoshop was reported by nothing. What Adobe does publish is the
/// same product catalog Creative Cloud's own installer reads; pairing it with Creative
/// Cloud's local record of what is installed (``AdobeProductInventory``) is enough to answer
/// the question, without a hand-maintained table of Adobe's product line.
///
/// Deliberately **not** a ``VendorUpdateChecker``: that protocol's driver performs one HTTP
/// request per app, and this source is a single per-scan document shared by every Adobe app
/// (see ``AdobeCatalogClient``). The catalog and the inventory are handed in already
/// resolved, which also makes the whole decision a pure function.
public struct AdobeUpdateChecker: Sendable {
    private let catalog: AdobeProductCatalog
    private let inventory: [AdobeInstalledProduct]

    public init(catalog: AdobeProductCatalog, inventory: [AdobeInstalledProduct]) {
        self.catalog = catalog
        self.inventory = inventory
    }

    public func check(app: ApplicationInfo) -> ManualCheckResult {
        guard let product = AdobeProductInventory.product(matching: app, in: inventory) else {
            return .notApplicable
        }
        guard let latest = catalog.latestVersion(forSapCode: product.sapCode) else {
            // The product is installed but absent from the catalog — a discontinued or
            // enterprise-only SKU. Nothing is wrong and nothing is knowable, so this is not
            // a failure to report to the user.
            return .notApplicable
        }
        guard isUpgrade(installed: product.version, latest: latest) else { return .upToDate }
        return .outdated(ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: product.version,
            availableVersion: latest,
            source: .adobe(sapCode: product.sapCode)
        ))
    }
}
