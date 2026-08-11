import Foundation

/// A step of an upgrade that Homebrew announced in its output.
public enum BrewProgressEvent: Equatable, Sendable {
    /// A download started. The token is set only when brew named the package it fetches
    /// for; a parallel download batch names URLs, and a URL is not a package.
    case downloadStarted(token: String?)
    case packageStarted(token: String)
    case packageFinished(token: String)
}

/// Recognises the progress markers in Homebrew's piped output.
///
/// There is no percentage to read: `utils/curl.rb` adds `--silent` whenever stdout is not a
/// terminal, and Wega runs brew through pipes. Downloads also run in parallel by default
/// (`HOMEBREW_DOWNLOAD_CONCURRENCY` defaults to twice the core count), so the order of
/// `==> Downloading` lines says nothing about what comes next. What remains reliable is the
/// serial start/finish markers below — which is why progress is counted in whole packages.
///
/// Only casks announce their own completion. A formula closes with its Cellar path
/// (`🍺  /opt/homebrew/Cellar/git/2.45.0: …`), which names no package, so formulae are
/// closed by the boundary rule in `UpgradeProgressTracker` instead.
public enum BrewUpgradeProgressParser {
    private static let installingCaskPrefix = "==> Installing Cask "
    private static let upgradingPrefix      = "==> Upgrading "
    private static let fetchingPrefix       = "==> Fetching downloads for: "
    private static let downloadingPrefix    = "==> Downloading "
    private static let successSuffixes      = [" was successfully upgraded!", " was successfully installed!"]

    public static func event(for rawLine: String) -> BrewProgressEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        if let token = token(in: line, after: installingCaskPrefix) {
            return .packageStarted(token: token)
        }
        if let token = token(in: line, after: upgradingPrefix) {
            return .packageStarted(token: token)
        }
        if line.hasPrefix(fetchingPrefix) {
            return .downloadStarted(token: token(in: line, after: fetchingPrefix))
        }
        if line.hasPrefix(downloadingPrefix) {
            return .downloadStarted(token: nil)
        }
        return finishedEvent(in: line)
    }

    private static func token(in line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return packageToken(String(line.dropFirst(prefix.count)))
    }

    private static func finishedEvent(in line: String) -> BrewProgressEvent? {
        for suffix in successSuffixes where line.hasSuffix(suffix) {
            let head = line.dropLast(suffix.count)
            guard let last = head.split(separator: " ").last,
                  let token = packageToken(String(last)) else { return nil }
            return .packageFinished(token: token)
        }
        return nil
    }

    /// One Homebrew package name — letters, digits and the punctuation taps and versioned
    /// formulae use. Whitespace disqualifies it (that is a sentence, not a token), and so
    /// does a leading slash (that is a Cellar path).
    private static func packageToken(_ candidate: String) -> String? {
        let token = candidate.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, token.count <= 80, !token.hasPrefix("/") else { return nil }
        let allowed = token.allSatisfy { $0.isLetter || $0.isNumber || "-_@+./".contains($0) }
        return allowed ? token : nil
    }
}
