import Foundation

/// The newest version Adobe publishes for each product, keyed by SAP code.
///
/// Adobe's feed lists *every* shipped version of a product, oldest first but not reliably
/// ordered, so the catalog is reduced to one entry per product at parse time: the rest is
/// history nothing in Wega asks about, and keeping it would make the on-disk cache an order
/// of magnitude larger than the answer it holds.
public struct AdobeProductCatalog: Codable, Equatable, Sendable {
    public var latestVersions: [String: String]

    public init(latestVersions: [String: String] = [:]) {
        self.latestVersions = latestVersions
    }

    public var isEmpty: Bool { latestVersions.isEmpty }

    public func latestVersion(forSapCode sapCode: String) -> String? {
        latestVersions[sapCode]
    }

    /// Parses the Creative Cloud product feed. Returns `nil` for a body that is not the
    /// expected XML at all (an error page, a truncated download); a well-formed document
    /// that happens to list no products parses to an empty catalog, which is a different
    /// thing and must not read as a failure.
    public static func parse(xml data: Data) -> AdobeProductCatalog? {
        let parser = XMLParser(data: data)
        let collector = ProductVersionCollector()
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return AdobeProductCatalog(latestVersions: collector.latestVersions)
    }
}

/// Collects `<product id="…" version="…">` attributes, keeping the newest version per id.
private final class ProductVersionCollector: NSObject, XMLParserDelegate {
    private(set) var latestVersions: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard elementName == "product",
              let sapCode = attributeDict["id"], !sapCode.isEmpty,
              let version = attributeDict["version"], !version.isEmpty else { return }
        guard let known = latestVersions[sapCode] else {
            latestVersions[sapCode] = version
            return
        }
        if isUpgrade(installed: known, latest: version) {
            latestVersions[sapCode] = version
        }
    }
}
