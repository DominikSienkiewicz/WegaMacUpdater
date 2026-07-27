import Foundation

/// SEC-09 — strips the two things that turn a diagnostic line into a profile of the
/// user's machine — filesystem paths and URL query strings — out of a message *before
/// it reaches the unified log*, where any process reading the system log could otherwise
/// read them back.
///
/// The redaction is scoped to the OSLog channel only. The persisted `wega.log` keeps the
/// full text: it is written `0600` (see ``LogStore``), readable only by its owner, and is
/// the place a developer actually reads paths and URLs back when diagnosing a failure.
public enum LogRedaction {
    static let pathPlaceholder = "[path]"
    static let queryPlaceholder = "?[query]"

    /// A `?key=value…` run: a `?` followed by a whitespace-free token containing an `=`.
    /// Anchored on the `=` so a bare "czy na pewno?" is left alone.
    private static let query = try? NSRegularExpression(
        pattern: #"\?[^\s"']*=[^\s"']*"#
    )

    /// An absolute POSIX path, `~`-relative path, or `file://` URL. The leading
    /// look-behind keeps it from biting into the middle of a word (`and/or`, `a/b`),
    /// while still firing after `file://` and at the start of a URL's path component.
    private static let path = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9._~%+-])(?:file://)?(?:~|/)(?:[A-Za-z0-9._+~%-]+/)+[A-Za-z0-9._+~%-]*"#
    )

    public static func redact(_ message: String) -> String {
        var out = message
        out = replace(query, in: out, with: queryPlaceholder)
        out = replace(path, in: out, with: pathPlaceholder)
        return out
    }

    private static func replace(_ regex: NSRegularExpression?, in string: String, with template: String) -> String {
        guard let regex else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }
}
