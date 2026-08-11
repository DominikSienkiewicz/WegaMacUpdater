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
    case rollback
    case uninstall
    case logs
}

/// Every destination, in the order the sidebar lists them.
///
/// The associated value on `updates` rules out a synthesised conformance, so this list is
/// written by hand — but it is the *only* hand-written list: the accessibility reading order
/// (`SidebarFocusPolicy`) is derived from it rather than repeating it, which is how a new
/// destination used to end up with sort priority `0`. The `rawValue` switch below is
/// exhaustive and has no `default`, so adding a case still fails the build until it is
/// spelled out there.
extension SidebarSelection: CaseIterable {
    public static let allCases: [SidebarSelection] = [
        .updates(.all),
        .updates(.apps),
        .updates(.cli),
        .updates(.security),
        .migration,
        .inventory,
        .rollback,
        .uninstall,
        .logs,
    ]
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
        case "rollback":         self = .rollback
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
        case .rollback:           return "rollback"
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

    static let initial: SidebarSelection = .updates(.all)

    /// The `UserDefaults` key the window's selection is stored under. Shared so the notification
    /// router can move the window without a second spelling of the same key (OBS-02).
    static let storageKey = "wega.sidebarSelection"

    /// Maps a pre-macOS-26 `@AppStorage("wega.activeTab")` value onto the new selection.
    /// That key stored only the tab, never the filter, so `update` restores the unfiltered list.
    /// Returns `nil` for an absent or unrecognised value, so the caller falls back to `initial`.
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
