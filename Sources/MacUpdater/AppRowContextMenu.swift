import MacUpdaterCore

/// UX-11d — the right-click actions offered on an installed-app row in the uninstall
/// list. Modelled as data so the menu's contents and wording are unit-testable without a
/// running view, and so every caller renders the identical menu (the same reason
/// `ManualUpdateActionView` renders its control from `UpdateActionKind`).
enum AppRowContextMenuAction: Hashable {
    /// Add the row to, or remove it from, the uninstall selection — the same effect as
    /// clicking the row.
    case toggleSelection
    /// Reveal the installation in Finder.
    case revealInFinder
    /// Copy the installation's filesystem path to the pasteboard.
    case copyPath
}

/// One entry in an app row's context menu: an action plus the label the view renders for it.
struct AppRowContextMenuItem: Identifiable, Equatable {
    let action: AppRowContextMenuAction
    let title: String
    let systemImage: String

    var id: AppRowContextMenuAction { action }
}

enum AppRowContextMenu {
    /// The menu items for one row, in display order. `isSelected` flips the toggle item's
    /// wording between adding the row to and removing it from the uninstall selection.
    static func items(isSelected: Bool) -> [AppRowContextMenuItem] {
        [
            AppRowContextMenuItem(
                action: .toggleSelection,
                title: isSelected ? tr("Odznacz") : tr("Zaznacz do odinstalowania"),
                systemImage: isSelected ? "square" : "checkmark.square"
            ),
            AppRowContextMenuItem(
                action: .revealInFinder,
                title: tr("Pokaż w Finderze"),
                systemImage: "folder"
            ),
            AppRowContextMenuItem(
                action: .copyPath,
                title: tr("Kopiuj ścieżkę"),
                systemImage: "doc.on.doc"
            ),
        ]
    }

    /// The clipboard string for a row — the installation's filesystem path.
    static func pathToCopy(for app: ApplicationInfo) -> String {
        app.path.path
    }
}
