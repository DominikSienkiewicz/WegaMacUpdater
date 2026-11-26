import SwiftUI

struct CleanupSpaceRecheckCard: View {
    let review: CleanupSpaceReview
    let recheck: () -> Void

    var body: some View {
        WegaCallout(level, title: tr("Miejsce na odroczoną aktualizację"), message: message, symbol: "internaldrive") {
            Button(tr("Sprawdź miejsce ponownie"), action: recheck)
                .disabled(review.reading == .checking)
        }
        .padding(.horizontal, WegaLayout.listGutter)
        .padding(.top, 8)
    }

    private var level: WegaCalloutLevel {
        if case .measured = review.reading, review.missingBytes == 0 { return .success }
        if case .unavailable = review.reading { return .warning }
        return .info
    }

    private var message: String {
        let required = size(review.requiredBytes)
        switch review.reading {
        case .atDeferral(let available):
            return trf("Przy próbie aktualizacji było %@ wolnego miejsca z wymaganych %@.", size(available), required)
        case .checking:
            return tr("Sprawdzam wolne miejsce…")
        case .unavailable:
            return trf("Nie udało się odczytać wolnego miejsca. Aktualizacja wymaga %@.", required)
        case .measured(let available):
            if let missing = review.missingBytes, missing > 0 {
                return trf("Dostępne %@ z wymaganych %@. Zwolnij jeszcze %@.", size(available), required, size(missing))
            }
            return trf("Miejsca wystarczy. Dostępne %@ przy wymaganych %@.", size(available), required)
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
