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
/// frazie (dopasowanie w treści LUB w etykiecie kategorii, bez rozróżniania
/// wielkości liter).
public func filterLogEntries(_ entries: [LogEntry], level: LogLevelFilter, search: String) -> [LogEntry] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    return entries.filter { e in
        guard level.includes(e.level) else { return false }
        guard !q.isEmpty else { return true }
        return e.message.lowercased().contains(q) || e.category.label.lowercased().contains(q)
    }
}
