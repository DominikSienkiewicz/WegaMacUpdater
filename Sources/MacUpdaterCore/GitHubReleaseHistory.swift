import Foundation

/// The shared reading of a GitHub releases list: which releases count, which one is newest,
/// and what a user on a given version has not seen yet.
///
/// Both readers of that endpoint go through here — `ReleaseHistoryFetcher` for Wega's own
/// update and `GitHubReleasesChecker` for catalogued apps — so the draft/prerelease rule and
/// REL-11's SemVer ordering are stated once instead of once per caller.
enum GitHubReleaseHistory {
    /// `nil` when the payload could not be read at all — distinct from a repository that has
    /// published nothing stable, which is an empty array.
    static func stableReleases(from data: Data) -> [GitHubRelease]? {
        guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            return nil
        }
        return releases.filter { !$0.draft && !$0.prerelease }
    }

    /// The highest version among them — never merely the first row. GitHub orders the list by
    /// creation date, which is not the same as by version once a patch for an older line ships
    /// after a newer minor.
    static func newest(_ releases: [GitHubRelease]) -> GitHubRelease? {
        releases.max { lhs, rhs in
            compareVersions(normalizeGitTag(lhs.tagName), normalizeGitTag(rhs.tagName), scheme: .semver)
                == .orderedAscending
        }
    }

    /// Everything published above `installed`, newest first, capped, with the remainder
    /// counted in `omitted` rather than dropped silently. Bodies are sanitised here, so what
    /// leaves this function is plain text.
    static func history(_ releases: [GitHubRelease], newerThan installed: String, limit: Int) -> ReleaseHistory {
        let newer = releases
            .map { (release: $0, version: normalizeGitTag($0.tagName)) }
            .filter { isUpgrade(installed: installed, latest: $0.version, scheme: .semver) }
            .sorted { compareVersions($0.version, $1.version, scheme: .semver) == .orderedDescending }

        let kept = newer.prefix(limit).map { entry in
            ReleaseNote(
                version: entry.version,
                publishedAt: entry.release.publishedAt.flatMap(iso8601Date(from:)),
                body: ReleaseNotesText.plain(fromHTML: entry.release.body ?? "")
            )
        }

        return ReleaseHistory(notes: Array(kept), omitted: max(0, newer.count - kept.count))
    }

    static func iso8601Date(from iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
