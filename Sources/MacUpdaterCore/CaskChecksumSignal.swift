import Foundation

/// The cask token whose Homebrew download checksum applies to this update, or nil when the
/// checksum signal doesn't apply. Only a plain `.cask` source is backed by `caskDownloads`;
/// other cask-adjacent sources (jetbrains, self-updating apps) are surfaced by different checkers
/// and have no checksum entry, so returning nil keeps the Trust panel from showing a false "absent"
/// (I-4).
public func caskChecksumToken(of source: ManualOutdatedApp.UpdateSource) -> String? {
    if case .cask(let token) = source { return token }
    return nil
}

/// The checksum-verification signal for a cask's Homebrew download, as far as Wega currently
/// knows (UX-05).
///
/// The point of the third `unknown` case: `caskDownloads` is populated only by a full scan and
/// is NOT restored from disk by `restoreLastScan`. Right after a relaunch it is therefore empty
/// for every cask — which is *missing data*, not a verdict. Collapsing it onto `absent` would
/// paint every cask with a red "no checksum" shield after every restart. `unknown` keeps that
/// distinction: a cask we simply have not fetched download info for yet is never a negative
/// verdict, while a `no_check` cask that we *did* fetch stays a real `absent`.
public enum CaskChecksumSignal: Equatable, Sendable {
    /// Not a plain cask — there is no checksum question to answer, so the panel shows no row.
    case notApplicable
    /// A cask whose download info has not been fetched yet. Rendered as "nieznane", never a warning.
    case unknown
    /// Homebrew will verify the download against a real sha256.
    case present
    /// The cask installs without checksum verification (`no_check` / missing sha256).
    case absent

    /// Bridges to the `Bool?` that `trustLevel(...)` consumes: an *unknown* (or not-applicable)
    /// signal contributes nothing to the verdict — exactly like "not a cask" — so it can never
    /// force a warning. Only a genuinely `absent` checksum is a red flag.
    public var checksumPresence: Bool? {
        switch self {
        case .present:                return true
        case .absent:                 return false
        case .unknown, .notApplicable: return nil
        }
    }
}

/// The checksum signal for a manual app's source, given the download info known so far. Only a
/// plain `.cask` source is backed by `caskDownloads`; every other source is `.notApplicable`.
public func caskChecksumSignal(
    of source: ManualOutdatedApp.UpdateSource,
    downloads: [String: CaskDownloadInfo]
) -> CaskChecksumSignal {
    caskChecksumSignal(token: caskChecksumToken(of: source), downloads: downloads)
}

/// The checksum signal for a plain cask token (an outdated cask row), given the download info
/// known so far. A `nil` token is not a cask; a token with no `caskDownloads` entry is *unknown*
/// (missing data, e.g. right after a relaunch) — never a false `absent`.
public func caskChecksumSignal(
    token: String?,
    downloads: [String: CaskDownloadInfo]
) -> CaskChecksumSignal {
    guard let token else { return .notApplicable }
    guard let info = downloads[token] else { return .unknown }
    return info.hasChecksum ? .present : .absent
}
