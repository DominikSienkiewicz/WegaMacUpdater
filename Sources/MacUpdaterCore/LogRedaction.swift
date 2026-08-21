import Foundation

/// SEC-09 — strips the things that turn a diagnostic line into a profile of the
/// user's machine — filesystem paths, URL query strings, credentials and e-mail
/// addresses — out of a message *before it reaches the unified log*, where any
/// process reading the system log could otherwise read them back.
///
/// The redaction is scoped to the OSLog channel only. The persisted `wega.log` keeps the
/// full text: it is written `0600` (see ``LogStore``), readable only by its owner, and is
/// the place a developer actually reads paths and URLs back when diagnosing a failure.
///
/// OBS-02 — a diagnostics bundle is the one artefact that deliberately *leaves* the
/// machine, so it may not carry even the parts `wega.log` is allowed to keep. Everything
/// that goes into one passes through ``redactForExport(_:userNames:)``, which applies the
/// same rules **plus** the account names that identify the person behind the machine.
public enum LogRedaction {
    static let pathPlaceholder = "[path]"
    static let queryPlaceholder = "?[query]"
    static let secretPlaceholder = "[secret]"
    static let emailPlaceholder = "[email]"
    static let userPlaceholder = "[user]"

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

    /// A PEM-armoured private key pasted or echoed into a message. Matched first and
    /// whole, because its body is base64 that every other rule here would leave alone.
    private static let pemBlock = try? NSRegularExpression(
        pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
    )

    /// `Authorization: <scheme> <credential>` — the header itself, whatever scheme it
    /// carries. The scheme word is matched explicitly rather than as "one more token", so
    /// the credential after `Basic`/`Bearer` is swallowed too without the pattern running
    /// on into the rest of the line.
    ///
    /// The gaps are `[^\S\n]` (horizontal whitespace) rather than `\s`, so a line that ends
    /// on the header name alone cannot reach across the newline and eat the next entry.
    private static let authorizationHeader = try? NSRegularExpression(
        pattern: #"(?i)\b(?:proxy-)?authorization\b[^\S\n]*[:=][^\S\n]*"#
            + #"(?:(?:bearer|basic|digest|token|negotiate)[^\S\n]+)?\S+"#
    )

    /// A bearer credential outside a header, e.g. `curl -H "Bearer ghp_…"` flattened
    /// into one log line. Horizontal whitespace only, for the same reason.
    private static let bearerToken = try? NSRegularExpression(
        pattern: #"(?i)\bbearer[^\S\n]+[A-Za-z0-9._~+/=-]{8,}"#
    )

    /// A labelled credential: `token=…`, `api_key: …`, `password="…"`. The label is kept
    /// so the line still says *what* was removed; only the value is replaced.
    ///
    /// Both quoted alternatives stop at a newline. An unterminated quote is routine — a
    /// truncated line, or Homebrew's `Error: Cask 'foo' is not installed` — and an
    /// unbounded `"[^"]*"` would run to the next quote *anywhere in the file*, deleting
    /// every entry in between. Falling back to `\S+` still redacts the value on its line.
    private static let labelledSecret = try? NSRegularExpression(
        pattern: #"(?i)\b(token|secret|passphrase|password|passwd|api[_-]?key|access[_-]?key|client[_-]?secret)"#
            + #"([^\S\n]*[:=][^\S\n]*)("[^"\n]*"|'[^'\n]*'|\S+)"#
    )

    /// Credentials recognisable by shape alone, so they are caught even when nothing
    /// labels them: GitHub PATs, Slack tokens, OpenAI-style keys, AWS access key IDs
    /// and JWTs.
    private static let shapedSecret = try? NSRegularExpression(
        pattern: #"\b(?:gh[pousr]_[A-Za-z0-9]{16,}"#
            + #"|github_pat_[A-Za-z0-9_]{20,}"#
            + #"|xox[baprsen]-[A-Za-z0-9-]{10,}"#
            + #"|sk-[A-Za-z0-9_-]{20,}"#
            + #"|AKIA[0-9A-Z]{16}"#
            + #"|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"#
    )

    private static let email = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    )

    public static func redact(_ message: String) -> String {
        var out = message
        out = replace(pemBlock, in: out, with: secretPlaceholder)
        out = replace(query, in: out, with: queryPlaceholder)
        out = replace(authorizationHeader, in: out, with: secretPlaceholder)
        out = replace(bearerToken, in: out, with: secretPlaceholder)
        out = replace(labelledSecret, in: out, with: "$1$2\(secretPlaceholder)")
        out = replace(shapedSecret, in: out, with: secretPlaceholder)
        out = replace(email, in: out, with: emailPlaceholder)
        out = replace(path, in: out, with: pathPlaceholder)
        return out
    }

    /// OBS-02 — ``redact(_:)`` plus the account names of the person using the machine.
    ///
    /// Paths already collapse to `[path]`, which removes the home directory — but a bare
    /// "użytkownik alice" or a `sudo: alice` prefix carries the same identity with no
    /// slash anywhere in sight, and a diagnostics bundle attached to a bug report is read
    /// by strangers. Names are matched case-insensitively and only where they stand as a
    /// whole word, so a short login cannot shred unrelated text from the middle of one.
    ///
    /// - Parameter userNames: the names to remove. Defaults to the live account's short
    ///   name, full name and home-directory component; tests inject their own so the
    ///   guarantee is verifiable on any machine.
    public static func redactForExport(
        _ message: String,
        userNames: [String] = currentUserNames()
    ) -> String {
        var out = redact(message)
        for name in scrubbableNames(userNames) {
            out = replaceWholeWord(name, in: out, with: userPlaceholder)
        }
        return out
    }

    /// The account names ``redactForExport(_:userNames:)`` removes by default: the login
    /// name, the display name, and the home directory's own component (which can differ
    /// from both after a rename).
    public static func currentUserNames() -> [String] {
        var names = [NSUserName(), NSFullUserName()]
        names.append(FileManager.default.homeDirectoryForCurrentUser.lastPathComponent)
        // A display name is "Ala Kowalska"; each part identifies the person on its own.
        names.append(contentsOf: NSFullUserName().split(separator: " ").map(String.init))
        return names
    }

    /// Names too short or too generic to scrub safely. A two-character login would turn
    /// ordinary words into `[user]`; leaving it is the lesser harm, and every *path*
    /// containing it is redacted regardless.
    private static func scrubbableNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .filter { seen.insert($0.lowercased()).inserted }
            // Longest first: "Ala Kowalska" must go before "Ala".
            .sorted { $0.count > $1.count }
    }

    private static func replaceWholeWord(_ word: String, in string: String, with template: String) -> String {
        let pattern = #"(?i)(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![A-Za-z0-9_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        return replace(regex, in: string, with: template)
    }

    private static func replace(_ regex: NSRegularExpression?, in string: String, with template: String) -> String {
        guard let regex else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }
}
