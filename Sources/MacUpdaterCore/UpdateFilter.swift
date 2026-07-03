import Foundation

/// Which category of updates the Update list shows, driven by the sidebar.
public enum UpdateFilter: Equatable, Sendable {
    case all, apps, cli, security

    /// App-category sections (casks, App Store, self-updating apps) are visible.
    public var allowsApps: Bool { self == .all || self == .apps }
    /// CLI-category sections (formulae, npm) are visible.
    public var allowsCli: Bool { self == .all || self == .cli }
    /// Only security-flagged updates are shown (app sections filtered to security items, CLI sections hidden).
    public var isSecurityOnly: Bool { self == .security }
}
