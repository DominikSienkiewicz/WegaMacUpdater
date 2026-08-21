import Foundation

/// Poziom filtra zakładki Logi. UWAGA: `label` (tekst UI) jest dodawany w
/// rozszerzeniu w module `MacUpdater`, bo używa `tr(...)`.
public enum LogLevelFilter: CaseIterable, Identifiable, Sendable {
    case all, warningsAndUp, errorsOnly

    public var id: Self { self }

    public func includes(_ level: LogLevel) -> Bool {
        switch self {
        case .all:           return true
        case .warningsAndUp: return level == .warning || level == .error
        case .errorsOnly:    return level == .error
        }
    }
}

/// Czysta funkcja filtrowania — testowalna bez UI. Filtruje po poziomie i po
/// frazie (dopasowanie w treści, w etykiecie kategorii LUB w strukturalnym detalu
/// awarii, bez rozróżniania wielkości liter).
public func filterLogEntries(_ entries: [LogEntry], level: LogLevelFilter, search: String) -> [LogEntry] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    return entries.filter { e in
        guard level.includes(e.level) else { return false }
        guard !q.isEmpty else { return true }
        return e.message.lowercased().contains(q)
            || e.category.label.lowercased().contains(q)
            || detailMatches(e.detail, q)
    }
}

/// A failure's own words — the command that ran and the tail of its `stderr` — live on the
/// entry's detail, not in its message. They are as much part of "what this entry says" as
/// the message is, so the search has to reach them; without this, moving text out of N loose
/// messages and onto one detail silently breaks a search that used to match.
private func detailMatches(_ detail: LogDetail?, _ lowercasedQuery: String) -> Bool {
    guard let detail else { return false }
    if detail.fields.contains(where: { $0.value.lowercased().contains(lowercasedQuery) }) { return true }
    return detail.output?.lowercased().contains(lowercasedQuery) ?? false
}

/// UX-06 — why the log list is empty. An empty log ("nothing has happened") and a filter
/// that hides every entry ("nothing matches") are different situations, so the LogsView can
/// show a different state for each instead of one message that fits neither.
public enum LogEmptyReason: Equatable, Sendable {
    /// The log holds no entries at all.
    case noEntries
    /// Entries exist, but the active level/search filter hides all of them.
    case noFilterMatches
}

/// Classifies an empty log list. Returns `nil` when something is visible.
public func logEmptyReason(totalCount: Int, visibleCount: Int) -> LogEmptyReason? {
    guard visibleCount == 0 else { return nil }
    return totalCount == 0 ? .noEntries : .noFilterMatches
}
