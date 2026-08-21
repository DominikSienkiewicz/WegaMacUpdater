import Foundation

/// How one run's casks are split between the concurrent pool and the serial lane.
///
/// Casks are independent of each other — unlike formulae, which share dependencies — so
/// several may be upgraded at once. The exception is the admin-password prompt: `brew`
/// raises it from inside the cask's own `pkg` / `installer` / `preflight` stanza, and two
/// prompts racing for the screen is not a state a user can resolve. Those casks therefore
/// run one at a time, however much of the pool is free.
///
/// A cask with **no** known profile lands in the serial lane too. `caskProfiles` is filled
/// only by a full scan, so after `restoreLastScan()` it is empty — and "we don't know" must
/// not resolve to "safe to run three at once".
public struct CaskUpgradeLanes: Equatable, Sendable {
    /// Casks that install user-space artifacts only: safe several at a time.
    public let concurrent: [String]
    /// Casks that may raise an admin-password prompt, and casks whose profile is unknown.
    public let serial: [String]

    public init(tokens: [String], profiles: [String: CaskArtifactProfile]) {
        var concurrent: [String] = []
        var serial: [String] = []
        for token in tokens {
            // `== false` rather than a negated optional: it lets the unknown-profile case
            // (`nil`) fall to the serial lane without a second branch saying the same thing.
            if profiles[token]?.mayRequireAdminPassword == false {
                concurrent.append(token)
            } else {
                serial.append(token)
            }
        }
        self.concurrent = concurrent
        self.serial = serial
    }
}
