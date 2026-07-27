import Foundation

/// Replay/downgrade protection for the OTA catalog (SEC-07).
///
/// A signature answers "did the publisher write this?", never "is this the *current* one".
/// An old catalog carries an old signature that stays valid forever, so anyone who can
/// choose which bytes reach a client — a compromised CDN edge, a captive network, a proxy —
/// can pin that client to a catalog published before a fix, without forging anything.
///
/// The counter that closes it has to live inside the signed bytes, or rewriting it would be
/// free. ``AppCatalog/generation`` does; this is the policy that reads it.
public enum CatalogGenerationPolicy {
    /// Whether a freshly fetched catalog may replace what the client already trusts.
    ///
    /// Equality is allowed on purpose: re-serving the same catalog is ordinary CDN
    /// behaviour, not an attack, and refusing it would turn every cache miss into a failure.
    /// Only a genuine step *backwards* is refused.
    public static func accepts(candidate: Int, accepted: Int) -> Bool {
        candidate >= accepted
    }
}

/// The highest catalog generation this installation has accepted, persisted so the guard
/// survives the relaunch an attacker would otherwise only have to wait for.
/// `@unchecked` for one reason: `UserDefaults` is documented as thread-safe but is not
/// marked `Sendable`, and this has to travel inside the `Sendable` `CatalogRefresher`.
public struct CatalogGenerationLedger: @unchecked Sendable {
    public static let defaultsKey = "wega.catalog.acceptedGeneration"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `0` when nothing has been accepted yet, which is also the generation of every catalog
    /// published before the field existed — so a first run accepts anything and tightens
    /// from there.
    public var accepted: Int {
        defaults.integer(forKey: Self.defaultsKey)
    }

    public func accepts(_ candidate: Int) -> Bool {
        CatalogGenerationPolicy.accepts(candidate: candidate, accepted: accepted)
    }

    /// Raises the watermark. Never lowers it: accepting an equal generation must not make a
    /// later downgrade legal.
    public func record(_ candidate: Int) {
        guard candidate > accepted else { return }
        defaults.set(candidate, forKey: Self.defaultsKey)
    }
}
