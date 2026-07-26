import Foundation

/// The GitHub Releases API "latest release" payload, as a single `Decodable` shared by
/// every checker that reads it (`GitHubReleasesChecker`, `WegaSelfUpdateChecker`) so the
/// format has exactly one model instead of one per consumer.
///
/// `htmlURL` and `assets` are optional: the plain "is there a newer tag?" path needs only
/// the version and the draft/prerelease flags (and its fixtures omit the rest), while the
/// self-update path additionally follows the release page and its installer asset.
struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let htmlURL: String?
    let assets: [Asset]?

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case body
        case htmlURL = "html_url"
        case assets
    }
}
