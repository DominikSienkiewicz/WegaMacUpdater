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
    /// The generation this build ships, below which no fetched catalog may go.
    ///
    /// The persisted watermark only remembers what arrived over the air, so a build whose
    /// bundled catalog is *newer* than anything fetched would otherwise accept — and write —
    /// a document it already outranks. `0` leaves the ledger behaving exactly as before.
    private let floor: Int

    public init(defaults: UserDefaults = .standard, floor: Int = 0) {
        self.defaults = defaults
        self.floor = floor
    }

    /// `0` when nothing has been accepted yet, which is also the generation of every catalog
    /// published before the field existed — so a first run accepts anything at or above the
    /// floor and tightens from there.
    public var accepted: Int {
        max(defaults.integer(forKey: Self.defaultsKey), floor)
    }

    public func accepts(_ candidate: Int) -> Bool {
        CatalogGenerationPolicy.accepts(candidate: candidate, accepted: accepted)
    }

    /// Raises the watermark. Never lowers it: accepting an equal generation must not make a
    /// later downgrade legal.
    ///
    /// Measured against the *persisted* value, not ``accepted``: the floor is a read-side
    /// clamp, and folding it in here would make every fetch whose generation equals the
    /// build's — the normal case, since a release ships the catalog it just published — a
    /// silent no-op, leaving the watermark at `0` and the installation protected only by
    /// whatever build happens to be running. Only generations that actually arrived over the
    /// air are recorded, so the watermark still never absorbs the build's own number.
    public func record(_ candidate: Int) {
        guard candidate > defaults.integer(forKey: Self.defaultsKey) else { return }
        defaults.set(candidate, forKey: Self.defaultsKey)
    }
}
