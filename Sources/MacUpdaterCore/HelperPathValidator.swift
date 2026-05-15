import Foundation

public struct ValidatedRemovalPath: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case applicationBundle
        case applicationSupport
        case cache
        case preferencePlist
    }

    public var url: URL
    public var kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

public enum HelperPathValidationError: Error, Equatable, LocalizedError {
    case pathOutsideAllowlist(URL)
    case expectedApplicationBundle(URL)
    case bundleIdentifierMismatch(expected: String, actual: String?)

    public var errorDescription: String? {
        switch self {
        case .pathOutsideAllowlist(let url):
            return "Path is outside the privileged helper allowlist: \(url.path)"
        case .expectedApplicationBundle(let url):
            return "Expected a direct .app bundle path: \(url.path)"
        case .bundleIdentifierMismatch(let expected, let actual):
            return "Bundle identifier mismatch. Expected \(expected), got \(actual ?? "nil")."
        }
    }
}

public struct HelperPathPolicy {
    public var applicationsDirectory: URL
    public var homeDirectory: URL

    public init(
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.applicationsDirectory = applicationsDirectory
        self.homeDirectory = homeDirectory
    }

    public func validateRemovalPath(
        _ url: URL,
        expectedBundleIdentifier: String? = nil
    ) throws -> ValidatedRemovalPath {
        let canonicalURL = canonical(url)

        if canonicalURL.pathExtension == "app" {
            guard canonicalURL.isDirectChild(of: canonical(applicationsDirectory)) else {
                throw HelperPathValidationError.expectedApplicationBundle(canonicalURL)
            }

            if let expectedBundleIdentifier {
                let actual = Bundle(url: canonicalURL)?.bundleIdentifier
                guard actual == expectedBundleIdentifier else {
                    throw HelperPathValidationError.bundleIdentifierMismatch(
                        expected: expectedBundleIdentifier,
                        actual: actual
                    )
                }
            }

            return ValidatedRemovalPath(url: canonicalURL, kind: .applicationBundle)
        }

        let applicationSupport = canonical(
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        )
        if canonicalURL.isDirectChild(of: applicationSupport) {
            return ValidatedRemovalPath(url: canonicalURL, kind: .applicationSupport)
        }

        let caches = canonical(
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
        )
        if canonicalURL.isDirectChild(of: caches) {
            return ValidatedRemovalPath(url: canonicalURL, kind: .cache)
        }

        let preferences = canonical(
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Preferences", isDirectory: true)
        )
        if canonicalURL.pathExtension == "plist", canonicalURL.isDirectChild(of: preferences) {
            return ValidatedRemovalPath(url: canonicalURL, kind: .preferencePlist)
        }

        throw HelperPathValidationError.pathOutsideAllowlist(canonicalURL)
    }

    public func validateRemovalPaths(_ urls: [URL]) throws -> [ValidatedRemovalPath] {
        try urls.map { try validateRemovalPath($0) }
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private extension URL {
    func isDirectChild(of parent: URL) -> Bool {
        let childComponents = standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        guard childComponents.count == parentComponents.count + 1 else {
            return false
        }
        return Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }
}
