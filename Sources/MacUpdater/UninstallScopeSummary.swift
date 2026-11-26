import MacUpdaterCore

/// What the uninstall sheet will remove, and by which route. Names only the routes in use.
enum UninstallScopeSummary {
    static func headline(counts: UninstallDialogCounts, leftovers: Int, permanentCleanupCount: Int = 0) -> String {
        guard !counts.removesNothing else { return tr("Pokaż, czego nie usunięto") }
        var action = trp("Usuń %@ aplikacji", counts.brew + counts.trash)
        if permanentCleanupCount > 0 {
            action += ", " + trp("trwale wyczyść dane %@ pakietów Homebrew", permanentCleanupCount)
        }
        if leftovers > 0 { action += " " + trp("i przenieś %@ pozycji do Kosza", leftovers) }
        return action
    }

    static func text(counts: UninstallDialogCounts, leftovers: Int, zapMode: Bool) -> String {
        let toTrash = counts.trash + leftovers
        let zapNote = zapMode && counts.brew > 0
        if toTrash > 0, counts.brew > 0, zapNote {
            return trf("Do Kosza: %@ · Homebrew: %@ (resztki z zap nie trafiają do Kosza)", "\(toTrash)", "\(counts.brew)")
        }
        var routes: [String] = []
        if toTrash > 0 { routes.append(trf("Do Kosza: %@", "\(toTrash)")) }
        if counts.brew > 0 { routes.append(trf("Homebrew: %@", "\(counts.brew)")) }
        var line = routes.joined(separator: " · ")
        if zapNote { line += " " + tr("(resztki z zap nie trafiają do Kosza)") }
        return line
    }
}
