import MacUpdaterCore

/// What the uninstall sheet will remove, and by which route. Names only the routes in use.
enum UninstallScopeSummary {
    static func headline(counts: UninstallDialogCounts, leftovers: Int) -> String {
        let apps = trp("Usuń %@ aplikacji", counts.brew + counts.trash)
        guard leftovers > 0 else { return apps }
        return apps + " " + trp("i %@ wybranych resztek", leftovers)
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
