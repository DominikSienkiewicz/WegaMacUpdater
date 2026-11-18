import SwiftUI
import MacUpdaterCore

/// Presentation for `SidebarSelection`. Lives in the app target because `tr()` and `SidebarTab`
/// do; only `filter` could be computed in Core.
extension SidebarSelection {
    /// The legacy tab this selection belongs to. `WegaState.forTab(_:)` still keys off it, and
    /// `UpdateView.onNavigate` still speaks it.
    var tab: SidebarTab {
        switch self {
        case .updates:   return .update
        case .migration: return .migration
        case .inventory: return .inventory
        case .rollback:  return .rollback
        case .uninstall: return .uninstall
        case .cleanup:   return .cleanup
        case .logs:      return .logs
        }
    }

    var label: String {
        switch self {
        // UX-16 — one destination: the category is the scope bar's, not the title's.
        case .updates:            return tr("Aktualizacje")
        case .migration:          return tr("Do przepięcia")
        case .inventory:          return tr("Spis aplikacji")
        case .rollback:           return tr("Cofnij aktualizacje")
        case .uninstall:          return tr("Odinstaluj aplikacje")
        case .cleanup:            return tr("Porządki")
        case .logs:               return tr("Logi")
        }
    }

    /// Shown as `.navigationSubtitle`, where the deleted 44 pt strip showed `SidebarTab.hint`.
    var hint: String { tab.hint }

    var systemImage: String {
        switch self {
        case .updates(.all):      return "arrow.triangle.2.circlepath"
        case .updates(.apps):     return "square.grid.2x2"
        case .updates(.cli):      return "terminal"
        case .updates(.security): return "shield.lefthalf.filled"
        case .migration:          return "arrow.right.doc.on.clipboard"
        case .inventory:          return "tablecells"
        case .rollback:           return "arrow.uturn.backward.circle"
        case .uninstall:          return "trash"
        case .cleanup:            return "sparkles"
        case .logs:               return "doc.text.magnifyingglass"
        }
    }

    /// Widens `UpdateView.onNavigate`'s `SidebarTab` back into a selection.
    static func forTab(_ tab: SidebarTab) -> SidebarSelection {
        switch tab {
        case .update:    return .updates(.all)
        case .rollback:  return .rollback
        case .uninstall: return .uninstall
        case .cleanup:   return .cleanup
        case .migration: return .migration
        case .inventory: return .inventory
        case .logs:      return .logs
        }
    }
}

/// UX-16 — the sidebar shows one Updates row; the category filter lives in the scope bar
/// above the list but still travels in the selection, so it is persisted and restored.
extension SidebarSelection {
    /// The sidebar row this selection highlights: every filtered Updates list is the one row.
    var sidebarRow: SidebarSelection {
        if case .updates = self { return .updates(.all) }
        return self
    }

    /// The selection after the user picks `pick` in the sidebar. Picking the Updates row while
    /// already on Updates keeps the chosen scope; arriving from elsewhere starts unfiltered.
    func applyingSidebarPick(_ pick: SidebarSelection) -> SidebarSelection {
        if case .updates = pick, case .updates = self { return self }
        return pick
    }
}
