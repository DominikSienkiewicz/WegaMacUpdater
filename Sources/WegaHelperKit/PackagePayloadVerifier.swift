import Foundation

/// Validates the flat, root-installed component package produced by `build-pkg.sh`.
/// Callers must authenticate the package before expanding its payload.
public enum PackagePayloadVerifier {
    public enum Failure: Error, LocalizedError {
        case missingExpectation
        case unexpectedPackage(String)
        case expansionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingExpectation: return "Brak oczekiwanej tożsamości lub wersji pakietu aktualizacji."
            case .unexpectedPackage(let detail): return "Pakiet aktualizacji ma nieoczekiwaną zawartość: \(detail)"
            case .expansionFailed(let detail): return "Nie udało się odczytać zawartości pakietu: \(detail)"
            }
        }
    }

    public static let installedAppURL = URL(fileURLWithPath: "/Applications/WegaMacUpdater.app", isDirectory: true)

    static func verify(at package: URL, teamID: String, bundleID: String?, expectedVersion: String?) throws {
        guard let bundleID, !bundleID.isEmpty, let expectedVersion, !expectedVersion.isEmpty else {
            throw Failure.missingExpectation
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let expanded = directory.appendingPathComponent("expanded", isDirectory: true)
        let result = try BoundedProcess.run(
            URL(fileURLWithPath: "/usr/sbin/pkgutil"),
            arguments: ["--expand-full", package.path, expanded.path], timeouts: .query
        )
        guard result.exitCode == 0 else { throw Failure.expansionFailed(result.standardError) }
        try verifyExpanded(at: expanded, bundleID: bundleID, expectedVersion: expectedVersion) { app in
            try CodeSignatureVerifier.verifyStaticCode(at: app, expectedTeamID: teamID, bundleID: bundleID)
        }
    }

    static func verifyExpanded(
        at root: URL, bundleID: String, expectedVersion: String,
        verifySignature: (URL) throws -> Void
    ) throws {
        let metadata = try Data(contentsOf: root.appendingPathComponent("PackageInfo"))
        try validateMetadata(metadata, bundleID: bundleID, expectedVersion: expectedVersion)
        let app = root.appendingPathComponent("Payload/Applications/WegaMacUpdater.app", isDirectory: true)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard app.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) else {
            throw Failure.unexpectedPackage("ścieżka aplikacji poza pakietem")
        }
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure.unexpectedPackage("identyfikator aplikacji")
        }
        try verifySignature(app)
        try CodeSignatureVerifier.verifyVersion(ofBundleAt: app, expectedVersion: expectedVersion)
    }

    static func validateMetadata(_ data: Data, bundleID: String, expectedVersion: String) throws {
        let delegate = PackageInfoParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.rootElement == "pkg-info", delegate.packageCount == 1,
              let attributes = delegate.attributes,
              attributes["identifier"] == bundleID,
              attributes["version"] == expectedVersion,
              attributes["install-location"] == "/" else {
            throw Failure.unexpectedPackage("PackageInfo: oczekiwano \(bundleID), wersja \(expectedVersion), cel /")
        }
    }
}

private final class PackageInfoParser: NSObject, XMLParserDelegate {
    var rootElement: String?
    var attributes: [String: String]?
    var packageCount = 0

    func parser(
        _: XMLParser, didStartElement elementName: String, namespaceURI _: String?,
        qualifiedName _: String?, attributes attributeDict: [String: String]
    ) {
        if rootElement == nil { rootElement = elementName }
        if elementName == "pkg-info" {
            packageCount += 1
            attributes = attributeDict
        }
    }
}
