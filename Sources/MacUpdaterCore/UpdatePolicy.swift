import Foundation

/// A user decision to mute or cap updates for one app/package — the "don't update
/// Zoom" / "pin Parallels to 18" need that auto-updaters create.
public enum UpdatePolicy: Codable, Equatable, Sendable {
    /// Never surface updates for this item.
    case ignored
    /// Surface updates only up to (and including) this version — anything newer is
    /// hidden. Pinning to the currently installed version means "hold here".
    case pinned(version: String)
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
    /// Identity used to look up a policy. Manual apps are keyed by name (lowercased)
    /// so a rule survives even if the detecting source changes.
    public var policyKey: String { "manual:" + name.lowercased() }
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
