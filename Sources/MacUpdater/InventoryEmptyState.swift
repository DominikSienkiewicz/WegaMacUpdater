import Foundation
import MacUpdaterCore

/// What the inventory list says when it has no rows. An inventory scan only reads installed
/// apps, so neither state claims anything was changed or checked for updates.
enum InventoryEmptyState: Equatable {
    /// Apps were read, but the filters hide every one of them.
    case noMatches
    /// The read finished without finding a single app.
    case nothingRead

    /// `nil` while scanning, before the first read, when the read failed (the error banner
    /// speaks) and whenever there are rows to show.
    static func of(appCount: Int, rowCount: Int, isScanning: Bool, hasError: Bool, lastReadAt: Date?) -> InventoryEmptyState? {
        guard !isScanning, !hasError, lastReadAt != nil, rowCount == 0 else { return nil }
        return appCount > 0 ? .noMatches : .nothingRead
    }

    var message: String {
        switch self {
        case .noMatches: tr("Żadna aplikacja nie pasuje do tych filtrów.")
        case .nothingRead: tr("Nie znalazłam aplikacji w wybranych folderach. Sprawdź katalogi skanowania albo odśwież spis.")
        }
    }
}
