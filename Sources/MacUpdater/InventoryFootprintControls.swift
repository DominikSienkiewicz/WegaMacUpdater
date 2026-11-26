import SwiftUI
import MacUpdaterCore

struct InventoryFootprintControls: View {
    @Binding var sortKey: InventorySortKey
    @Binding var ascending: Bool
    let measurement: InventoryFootprintMeasurement?
    let measuring: Bool
    let failed: Bool
    let scope: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker(tr("Pomiar miejsca"), selection: Binding(get: { sortKey }, set: {
                    sortKey = $0
                    ascending = false
                })) {
                    Text(tr("Rozmiar")).tag(InventorySortKey.diskUsage)
                    Text(tr("Zmiana od pomiaru")).tag(InventorySortKey.diskGrowth)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                if failed {
                    Text(tr("Pomiar nie powiódł się. Odśwież spis, aby spróbować ponownie."))
                } else if measuring {
                    ProgressView().controlSize(.small).accessibilityLabel(tr("Obliczanie rozmiarów aplikacji"))
                } else if sortKey == .diskGrowth, let measurement {
                    if let date = measurement.previousDate {
                        Text(trf("Poprzedni pomiar: %@", date.formatted(date: .abbreviated, time: .shortened)))
                    } else {
                        Text(tr("Pierwszy pomiar. Odśwież spis później, aby zobaczyć zmiany."))
                    }
                }
                Spacer(minLength: 0)
            }
            if sortKey == .diskUsage { Text(scope) }
            if measurement?.saved == false { Text(tr("Nie udało się zapisać pomiaru na dysku. Jest dostępny w tej sesji.")) }
        }
        .font(.wega(.footnote))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
