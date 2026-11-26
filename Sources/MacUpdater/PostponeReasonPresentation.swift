import Foundation
import MacUpdaterCore

extension PostponeReason {
    var diskShortfall: Int64? {
        guard case .insufficientDisk(let required, let available) = self else { return nil }
        return max(0, max(0, required) - max(0, available))
    }

    var updateBanner: BannerData {
        BannerData(variant: .danger, title: tr("Odkładam pobieranie"), message: localizedMessage,
                   action: diskShortfall == nil ? .openLogs : .openCleanup)
    }

    /// The reason in the active language, always ending with the user's next step.
    var localizedMessage: String {
        switch self {
        case .meteredNetwork:
            return tr("To połączenie ma ograniczony transfer. Użyj innej sieci albo zmień Warunki aktualizacji.")
        case .lowDataMode:
            return tr("Włączony jest tryb oszczędzania danych. Wyłącz go albo użyj innej sieci.")
        case .thermal:
            return tr("Mac jest zbyt gorący. Poczekaj, aż ostygnie.")
        case .lowBattery:
            return tr("Niski poziom baterii. Podłącz zasilanie i spróbuj ponownie.")
        case .diskSpaceUnknown:
            return tr("Nie mogę odczytać wolnego miejsca. Spróbuj ponownie; jeśli to wróci, otwórz Logi.")
        case .insufficientDisk:
            let size = ByteCountFormatter.string(fromByteCount: diskShortfall ?? 0, countStyle: .file)
            return trf("Do aktualizacji brakuje około %@. Zwolnij miejsce i spróbuj ponownie.", size)
        }
    }

    /// The line a postponed run writes to its log. The reason already ends in a full stop, so
    /// the frame around it adds none.
    var logLine: String {
        "⏸ " + trf("Aktualizacja odroczona: %@", localizedMessage)
    }
}
