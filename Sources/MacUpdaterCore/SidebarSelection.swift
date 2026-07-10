import Foundation

/// The sidebar's single navigation coordinate.
///
/// The window used to track two independent values: which tab is active, and — for the Updates
/// tab only — which category filter is applied. `NavigationSplitView` selects on one `Hashable`
/// value, so the two axes collapse here.
public enum SidebarSelection: Hashable, Sendable {
    case updates(UpdateFilter)
    case migration
    case inventory
    case uninstall
    case logs
}

extension SidebarSelection: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "updates.all":      self = .updates(.all)
        case "updates.apps":     self = .updates(.apps)
        case "updates.cli":      self = .updates(.cli)
        case "updates.security": self = .updates(.security)
        case "migration":        self = .migration
        case "inventory":        self = .inventory
        case "uninstall":        self = .uninstall
        case "logs":             self = .logs
        default:                 return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .updates(.all):      return "updates.all"
        case .updates(.apps):     return "updates.apps"
        case .updates(.cli):      return "updates.cli"
        case .updates(.security): return "updates.security"
        case .migration:          return "migration"
        case .inventory:          return "inventory"
        case .uninstall:          return "uninstall"
        case .logs:               return "logs"
        }
    }
}

public extension SidebarSelection {
    /// The category filter for the Updates list; `nil` on every other destination.
    var filter: UpdateFilter? {
        guard case .updates(let filter) = self else { return nil }
        return filter
    }

    static let `default`: SidebarSelection = .updates(.all)

    /// Maps a pre-macOS-26 `@AppStorage("wega.activeTab")` value onto the new selection.
    /// That key stored only the tab, never the filter, so `update` restores the unfiltered list.
    /// Returns `nil` for an absent or unrecognised value, so the caller falls back to `default`.
    static func migrating(legacyTab: String?) -> SidebarSelection? {
        switch legacyTab {
        case "update":    return .updates(.all)
        case "uninstall": return .uninstall
        case "migration": return .migration
        case "inventory": return .inventory
        case "logs":      return .logs
        default:          return nil
        }
    }
}
