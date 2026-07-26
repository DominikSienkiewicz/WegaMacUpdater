import Foundation

/// A user decision to mute or cap updates for one app/package — the "don't update
/// Zoom" / "pin Parallels to 18" need that auto-updaters create.
public enum UpdatePolicy: Codable, Equatable, Sendable {
    /// Never surface updates for this item.
    case ignored
    /// Surface updates only up to (and including) this version — anything newer is
    /// hidden. Pinning to the currently installed version means "hold here".
    case pinned(version: String)
    /// Hide only this one specific version; the next release surfaces again. The
    /// "skip X, show X+1" pattern that `pinned` can't express — a pin to the current
    /// version also hides every future release.
    case skipped(version: String)
}

/// A persisted policy plus the metadata needed to render and manage it.
public struct UpdatePolicyEntry: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var displayName: String
    public var policy: UpdatePolicy

    public var id: String { key }

    public init(key: String, displayName: String, policy: UpdatePolicy) {
        self.key = key
        self.displayName = displayName
        self.policy = policy
    }
}

// MARK: - Stable identity for policy lookup

extension OutdatedItem {
    /// Identity used to look up a policy. Reuses the source-tagged selection key
    /// (`f:`/`c:`/`a:`/`n:`), which is stable across scans.
    public var policyKey: String { key }
}

extension ManualOutdatedApp {
    /// Identity used to look up a policy. REL-11: keyed by the stable installation
    /// identity — `bundle ID + path` — not the display name. Keying by name lost the
    /// user's ignore/pin the moment a vendor renamed the app across versions; the
    /// bundle identifier and on-disk path both survive that rename. The `path`
    /// component (an ``InstallationIdentity``) also keeps two copies of one app —
    /// `/Applications` vs `~/Applications` — as distinct policy targets.
    public var policyKey: String {
        "manual:" + (bundleIdentifier ?? "") + "|" + InstallationIdentity(path: path).rawValue
    }
}

// MARK: - Filtering

extension UpdatePlanner {
    /// Whether an update should be hidden under the active policies.
    public static func isSuppressed(
        key: String,
        availableVersion: String?,
        policies: [String: UpdatePolicy]
    ) -> Bool {
        guard let policy = policies[key] else { return false }
        switch policy {
        case .ignored:
            return true
        case .pinned(let pinnedVersion):
            // No version to compare → conservatively hide (the user asked to hold).
            guard let available = availableVersion, !available.isEmpty else { return true }
            // Hide only when the available version is an upgrade *beyond* the pin.
            return isUpgrade(installed: pinnedVersion, latest: available)
        case .skipped(let skippedVersion):
            // Skip is deliberately narrow: hide only the exact version the user skipped;
            // any other (newer) release surfaces again. With no version to match, show it
            // rather than over-hide — the whole point is not to lose future releases.
            guard let available = availableVersion, !available.isEmpty else { return false }
            return versionsEqual(available, skippedVersion)
        }
    }

    public static func applyPolicies(_ items: [OutdatedItem], policies: [String: UpdatePolicy]) -> [OutdatedItem] {
        guard !policies.isEmpty else { return items }
        return items.filter { !isSuppressed(key: $0.policyKey, availableVersion: $0.to, policies: policies) }
    }

    public static func applyPolicies(_ apps: [ManualOutdatedApp], policies: [String: UpdatePolicy]) -> [ManualOutdatedApp] {
        guard !policies.isEmpty else { return apps }
        return apps.filter { !isSuppressed(key: $0.policyKey, availableVersion: $0.availableVersion, policies: policies) }
    }
}
