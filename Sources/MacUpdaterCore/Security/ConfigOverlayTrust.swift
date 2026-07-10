import Foundation

/// How much a config overlay has to prove before it is applied (F5a).
///
/// The two overlay files enter the app from opposite directions, so they cannot share one
/// policy:
///
/// - **`app-catalog.json`** is fetched from a public repository that accepts pull requests.
///   A hostile entry there reaches every user. It is **fail-closed**: no valid detached
///   signature, no overlay — fall back to the catalog compiled into the build.
/// - **`endpoints.json`** is a file the user drops into their own Application Support
///   directory to follow a feed a vendor has moved, without waiting for a release. Requiring
///   a signature there protects nothing: anyone able to write that file can already do worse
///   to the account. So it stays usable **unsigned**, and each unsigned use is logged.
///
/// The case both policies agree on: a signature that is present and *wrong* means tampering,
/// not convenience, and is refused either way.
public enum ConfigOverlayTrust {
    public enum Decision: Equatable, Sendable {
        /// Signed and verified — or signing is not configured at all.
        case accept
        /// Applied without a signature, by policy. Worth a line in the log.
        case acceptUnsigned
        /// Refused. The caller falls back to its baseline.
        case reject

        public var appliesOverlay: Bool { self != .reject }

        public var deservesWarning: Bool { self == .acceptUnsigned }
    }

    /// `signature` is the detached signature read from `<file>.sig`, `nil` when absent.
    /// `isValid` is the result of verifying it — meaningless when `signature` is `nil`.
    public static func forCatalog(signingConfigured: Bool, signature: String?, isValid: Bool) -> Decision {
        guard signingConfigured else { return .accept }
        guard signature != nil, isValid else { return .reject }
        return .accept
    }

    public static func forEndpoints(signingConfigured: Bool, signature: String?, isValid: Bool) -> Decision {
        guard signingConfigured else { return .accept }
        guard signature != nil else { return .acceptUnsigned }
        return isValid ? .accept : .reject
    }
}
