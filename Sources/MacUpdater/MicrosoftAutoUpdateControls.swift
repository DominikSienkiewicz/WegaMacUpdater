import SwiftUI
import MacUpdaterCore

struct MicrosoftAutoUpdateControls: View {
    let app: ApplicationInfo
    var evidence: MicrosoftAutoUpdateEvidence?
    var item: ManualOutdatedApp?
    @EnvironmentObject private var scan: ScanStore
    @State private var openFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item == nil {
                Text("Microsoft AutoUpdate").font(.headline)
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: open) {
                Label(evidence?.status == .notInstalled ? tr("Otwórz pomoc Microsoft") : tr("Otwórz Microsoft AutoUpdate"),
                      systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            .disabled(!scan.allowsVendorCheck)
            .help(tr("Otwiera aktualizator Microsoft lub instrukcję jego instalacji. Wega nie uruchamia instalowania aktualizacji Office."))
            if openFailed {
                Text(tr("Nie udało się otworzyć aplikacji lub strony producenta."))
                    .font(.caption).foregroundStyle(Color.wegaDanger)
            }
        }
    }

    private var explanation: String {
        switch evidence?.status {
        case .notInstalled:
            tr("Nie znaleziono Microsoft AutoUpdate w standardowej lokalizacji. Aktualność tej kopii pozostaje niepotwierdzona.")
        case .unavailable:
            tr("Microsoft AutoUpdate nie odpowiedział. Otwórz go i sprawdź aktualizacje.")
        case .failed:
            tr("Nie udało się odczytać wyniku Microsoft AutoUpdate. Aktualność niepotwierdzona.")
        case .unrecognizedOutput:
            tr("Microsoft AutoUpdate zwrócił nierozpoznany wynik. Aktualność niepotwierdzona.")
        case .noUpdatesReported:
            tr("Microsoft AutoUpdate nie zgłosił aktualizacji. Nie potwierdza to rejestracji ani aktualności tej kopii.")
        case .updatesReported:
            tr("Microsoft AutoUpdate zgłosił oferty produktów. Rejestracja tej kopii nie została potwierdzona.")
        case nil:
            tr("Sprawdź tę instalację w Microsoft AutoUpdate. Brak wyniku nie potwierdza aktualności.")
        }
    }

    private func open() {
        let destination = MicrosoftAutoUpdateHandoff.destination(for: app)
        let succeeded = destination.map { NSWorkspace.shared.open($0) } ?? false
        openFailed = !succeeded
        if let item { scan.vendorOpened(item, succeeded: succeeded) }
    }
}
