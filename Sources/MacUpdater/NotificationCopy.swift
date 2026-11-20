import MacUpdaterCore

/// UXP-05 — the words of Wega's notifications. Every count goes through `trp`, so Polish and
/// English both get the right grammatical number.
enum NotificationCopy {
    /// How many app names the body spells out before it counts the rest.
    private static let namedApps = 2

    /// "Nowe aktualizacje: Slack, Zoom i 1 inna." — the first two apps by name, the rest counted.
    static func newUpdatesBody(names: [String]) -> String {
        let named = names.prefix(namedApps).joined(separator: ", ")
        let remaining = names.count - namedApps
        let tail = remaining > 0 ? " " + trp("i %@ innych", remaining) : ""
        return "\(tr("Nowe aktualizacje:")) \(named)\(tail)."
    }

    static func backgroundUpdatedClause(count: Int) -> String {
        trp("W tle zaktualizowałam %@ aplikacji.", count)
    }
}
