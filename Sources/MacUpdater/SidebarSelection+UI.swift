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
        case .uninstall: return .uninstall
        case .logs:      return .logs
        }
    }

    var label: String {
        switch self {
        case .updates(.all):      return tr("Wszystkie")
        case .updates(.apps):     return tr("Aplikacje")
        case .updates(.cli):      return tr("Narzędzia CLI")
        case .updates(.security): return tr("Poprawki bezp.")
        case .migration:          return tr("Do przepięcia")
        case .inventory:          return tr("Spis aplikacji")
        case .uninstall:          return tr("Odinstaluj aplikacje")
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
        case .uninstall:          return "trash"
        case .logs:               return "doc.text.magnifyingglass"
        }
    }

    /// Widens `UpdateView.onNavigate`'s `SidebarTab` back into a selection.
    static func forTab(_ tab: SidebarTab) -> SidebarSelection {
        switch tab {
        case .update:    return .updates(.all)
        case .uninstall: return .uninstall
        case .migration: return .migration
        case .inventory: return .inventory
        case .logs:      return .logs
        }
    }
}
