import Foundation

/// Pure builder for a prefilled GitHub "new issue" URL that asks the maintainers to add
/// an app the catalog does not yet know about.
///
/// It performs no I/O and never touches `NSWorkspace`: the caller injects the repository's
/// `issues/new` endpoint and opens the returned URL itself. Everything here is a
/// deterministic function of the inputs, so it is fully unit-testable in `MacUpdaterCore`.
public struct CatalogIssueBuilder: Sendable, Equatable {
    /// Hard cap on the generated URL length. GitHub (and browsers) reject very long URLs, so
    /// the body is truncated — the title never is — to keep the result under this bound.
    public static let maxURLLength = 8000

    /// Human-readable app name (e.g. `"Acme Studio"`).
    public var appName: String
    /// The app's bundle identifier the catalog failed to match.
    public var bundleID: String
    /// Optional `SUFeedURL` detected on the user's machine, if any.
    public var feedURL: String?
    /// Optional description of the version-string format observed (e.g. `"1.2.3"`).
    public var versionFormat: String?

    public init(appName: String, bundleID: String, feedURL: String? = nil, versionFormat: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.feedURL = feedURL
        self.versionFormat = versionFormat
    }

    /// Issue title. Falls back to the bundle ID when the app name is blank so the title is
    /// never empty. Never truncated by ``url(newIssueEndpoint:)``.
    public var title: String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? bundleID : trimmed
        return "[Catalog] Add update support for \(name)"
    }

    /// Markdown issue body. Optional lines are omitted when their value is absent or blank.
    public var body: String {
        var lines: [String] = [
            "Wega does not recognise this app yet. Details detected on this machine:",
            "",
            "- App name: \(appName)",
            "- Bundle ID: \(bundleID)",
        ]
        if let feedURL, !feedURL.isEmpty {
            lines.append("- Detected SUFeedURL: \(feedURL)")
        }
        if let versionFormat, !versionFormat.isEmpty {
            lines.append("- Version format: \(versionFormat)")
        }
        return lines.joined(separator: "\n")
    }

    /// Builds the prefilled URL against `newIssueEndpoint` (e.g. `.../issues/new`).
    ///
    /// The title and body are percent-encoded down to the RFC 3986 unreserved set, so every
    /// space, `&`, `#`, `+`, `/`, `?` and `:` is escaped. If the whole URL would exceed
    /// ``maxURLLength``, the body is truncated on whole-character boundaries (never splitting
    /// a percent triplet) while the title is kept intact. Returns `nil` only if the fixed
    /// title prefix alone already overflows the cap.
    public func url(newIssueEndpoint: URL) -> URL? {
        let prefix = "\(newIssueEndpoint.absoluteString)?title=\(Self.percentEncoded(title))&body="
        let budget = Self.maxURLLength - prefix.count
        guard budget > 0 else { return nil }

        var encodedBody = Self.percentEncoded(body)
        if encodedBody.count > budget {
            encodedBody = Self.truncatedEncodedBody(body, toEncodedLength: budget)
        }
        return URL(string: prefix + encodedBody)
    }

    // MARK: - Percent-encoding

    /// RFC 3986 unreserved characters only, so nothing that could break out of a query value
    /// (spaces, `&`, `#`, `+`, `/`, `?`, `:` …) survives unescaped.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func percentEncoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Returns the percent-encoded form of the longest whole-character prefix of `raw` whose
    /// encoding fits `limit`. Because encoded length grows monotonically with the prefix
    /// length, the boundary is found with a binary search — and cutting on `Character`
    /// boundaries guarantees a `%XX` triplet is never split.
    static func truncatedEncodedBody(_ raw: String, toEncodedLength limit: Int) -> String {
        let chars = Array(raw)
        var low = 0
        var high = chars.count
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if percentEncoded(String(chars[0..<mid])).count <= limit {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return percentEncoded(String(chars[0..<best]))
    }
}
